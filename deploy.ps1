# ==========================================
# SCRIPT DE DESPLIEGUE AWS (Corregido y Actualizado)
# ==========================================

# --- 1. CONFIGURACION ---
$env:AWS_REGION = "us-east-1"

# NOTA: Si usas tu propia cuenta personal (no Academy), cambia "LabRole" por el nombre de tu rol (ej. "AdminRole")
$CustomRoleName = "LabRole" 

Write-Host "Iniciando validacion de credenciales..." -ForegroundColor Cyan

# 1.1 Validar Credenciales AWS CLI
try {
    $identity = aws sts get-caller-identity --output json | ConvertFrom-Json
    $env:ACCOUNT_ID = $identity.Account
    Write-Host "Credenciales detectadas. Account ID: $($env:ACCOUNT_ID)" -ForegroundColor Green
} catch {
    Write-Error "ERROR FATAL: No se detectan credenciales de AWS. Ejecuta 'aws configure' o refresca tu sesion."
    exit 1
}

$env:BUCKET_NAME = "datalake-laptops-$($env:ACCOUNT_ID)"

# 1.2 Obtener ARN del Rol
try {
    $env:ROLE_ARN = (aws iam get-role --role-name $CustomRoleName --query 'Role.Arn' --output text).Trim()
    Write-Host "Rol encontrado: $($env:ROLE_ARN)" -ForegroundColor Green
} catch {
    Write-Error "ERROR CRITICO: No se encuentra el rol '$CustomRoleName'. Si estas en una cuenta personal, crea un rol con permisos de Admin o cambia la variable `$CustomRoleName` en el script."
    exit 1
}

Write-Host "------------------------------------------------" -ForegroundColor Cyan
Write-Host "RESUMEN DE DESPLIEGUE:"
Write-Host "Bucket: $($env:BUCKET_NAME)"
Write-Host "Region: $($env:AWS_REGION)"
Write-Host "------------------------------------------------" -ForegroundColor Cyan

# --- 2. S3 & KINESIS ---

Write-Host "Build: Creando Bucket S3..." -ForegroundColor Yellow
try {
    aws s3 mb s3://$env:BUCKET_NAME 2>$null
} catch {
    Write-Host "   INFO: El bucket ya existe o no se pudo crear (verificar permisos)." -ForegroundColor Gray
}

Write-Host "Build: Creando estructura de carpetas..." -ForegroundColor Yellow
# Redirigimos stderr a null para limpiar la salida si ya existen
aws s3api put-object --bucket $env:BUCKET_NAME --key raw/ 2>$null
aws s3api put-object --bucket $env:BUCKET_NAME --key raw/laptops_json/ 2>$null
aws s3api put-object --bucket $env:BUCKET_NAME --key processed/ 2>$null
aws s3api put-object --bucket $env:BUCKET_NAME --key config/ 2>$null
aws s3api put-object --bucket $env:BUCKET_NAME --key scripts/ 2>$null
aws s3api put-object --bucket $env:BUCKET_NAME --key logs/ 2>$null

Write-Host "Build: Creando Kinesis Stream..." -ForegroundColor Yellow
try {
    aws kinesis create-stream --stream-name energy-stream --shard-count 1 2>$null
} catch {
    Write-Host "   INFO: El stream probablemente ya existe." -ForegroundColor Gray
}

# --- 3. LAMBDA ---

Write-Host "Build: Empaquetando y desplegando Lambda..." -ForegroundColor Yellow

if (Test-Path "firehose.zip") { Remove-Item "firehose.zip" }
# Verificamos que exista el archivo python
if (-not (Test-Path "firehose.py")) {
    Write-Error "Falta el archivo 'firehose.py' en el directorio actual."
    exit 1
}
Compress-Archive -Path "firehose.py" -DestinationPath "firehose.zip"

# Intentar crear.
aws lambda create-function `
    --function-name laptops-firehose-lambda `
    --runtime python3.12 `
    --role $env:ROLE_ARN `
    --handler firehose.lambda_handler `
    --zip-file fileb://firehose.zip `
    --timeout 60 `
    --memory-size 128 2>$null

if (-not $?) {
    Write-Host "   -> La Lambda ya existe, actualizando codigo..." -ForegroundColor DarkGray
    aws lambda update-function-code --function-name laptops-firehose-lambda --zip-file fileb://firehose.zip >$null
}

# Esperar propagacion
Start-Sleep -Seconds 5

$env:LAMBDA_ARN = (aws lambda get-function --function-name laptops-firehose-lambda --query 'Configuration.FunctionArn' --output text).Trim()

# --- 4. FIREHOSE ---

Write-Host "Build: Creando Firehose Delivery Stream..." -ForegroundColor Yellow

# Objeto de configuracion para JSON
$firehoseConfig = @{
    BucketARN = "arn:aws:s3:::$env:BUCKET_NAME"
    RoleARN = "$env:ROLE_ARN"
    Prefix = "raw/laptops_json/processing_date=!{partitionKeyFromLambda:processing_date}/"
    ErrorOutputPrefix = "errors/!{firehose:error-output-type}/"
    BufferingHints = @{ SizeInMBs = 64; IntervalInSeconds = 60 }
    DynamicPartitioningConfiguration = @{ Enabled = $true; RetryOptions = @{ DurationInSeconds = 300 } }
    ProcessingConfiguration = @{
        Enabled = $true
        Processors = @(
            @{
                Type = "Lambda"
                Parameters = @(
                    @{ ParameterName = "LambdaArn"; ParameterValue = "$env:LAMBDA_ARN" },
                    @{ ParameterName = "BufferSizeInMBs"; ParameterValue = "1" },
                    @{ ParameterName = "BufferIntervalInSeconds"; ParameterValue = "60" }
                )
            }
        )
    }
}

$firehoseConfig | ConvertTo-Json -Depth 10 | Out-File "firehose_config.json" -Encoding ASCII

aws firehose create-delivery-stream `
    --delivery-stream-name laptops-delivery-stream `
    --delivery-stream-type KinesisStreamAsSource `
    --kinesis-stream-source-configuration "KinesisStreamARN=arn:aws:kinesis:$($env:AWS_REGION):$($env:ACCOUNT_ID):stream/energy-stream,RoleARN=$env:ROLE_ARN" `
    --extended-s3-destination-configuration file://firehose_config.json 2>$null

Remove-Item "firehose_config.json"

# --- 5. GLUE DATABASE & CRAWLER ---

Write-Host "Build: Configurando Glue..." -ForegroundColor Yellow

Set-Content -Path "glue_db.json" -Value '{"Name":"laptops_db"}'
aws glue create-database --database-input file://glue_db.json 2>$null
Remove-Item "glue_db.json"

$crawlerConfig = @{
    Name = "laptops-raw-crawler"
    Role = "$env:ROLE_ARN"
    DatabaseName = "laptops_db"
    Targets = @{ S3Targets = @( @{ Path = "s3://$env:BUCKET_NAME/raw/laptops_json" } ) }
}
$crawlerConfig | ConvertTo-Json -Depth 5 | Out-File "glue_crawler.json" -Encoding ASCII

aws glue create-crawler --cli-input-json file://glue_crawler.json 2>$null
Remove-Item "glue_crawler.json"

# Iniciar crawler si no esta corriendo
try {
    aws glue start-crawler --name laptops-raw-crawler 2>$null
} catch {}

# --- 6. GLUE JOBS ---

Write-Host "Build: Subiendo scripts y creando Glue Jobs..." -ForegroundColor Yellow

# Subida de scripts (Validando que existan)
if (-not (Test-Path "laptops_analytics_brand.py")) { Write-Error "Falta laptops_analytics_brand.py"; exit 1 }
# Aqui corregimos el nombre del archivo OS
if (-not (Test-Path "laptops_analytics_so.py")) { Write-Error "Falta laptops_analytics_so.py"; exit 1 }

aws s3 cp laptops_analytics_brand.py s3://$env:BUCKET_NAME/scripts/
aws s3 cp laptops_analytics_so.py s3://$env:BUCKET_NAME/scripts/

# --- JOB 1: MARCAS ---
$jobBrandConfig = @{
    Name = "laptops-analytics-brand"
    Role = "$env:ROLE_ARN"
    Command = @{
        Name = "glueetl"
        ScriptLocation = "s3://$env:BUCKET_NAME/scripts/laptops_analytics_brand.py"
        PythonVersion = "3"
    }
    DefaultArguments = @{
        "--database" = "laptops_db"
        "--table" = "laptops_json"
        "--output_path" = "s3://$env:BUCKET_NAME/processed/laptops_by_brand/"
        "--enable-continuous-cloudwatch-log" = "true"
        "--spark-event-logs-path" = "s3://$env:BUCKET_NAME/logs/"
    }
    GlueVersion = "4.0"
    NumberOfWorkers = 2
    WorkerType = "G.1X"
}
$jobBrandConfig | ConvertTo-Json -Depth 5 | Out-File "job_brand.json" -Encoding ASCII

aws glue create-job --cli-input-json file://job_brand.json 2>$null
if (-not $?) { aws glue update-job --job-name laptops-analytics-brand --job-update file://job_brand.json >$null }
Remove-Item "job_brand.json"

# --- JOB 2: OPSYS (Nombre de archivo corregido) ---
$jobOsConfig = @{
    Name = "laptops-analytics-opsys"
    Role = "$env:ROLE_ARN"
    Command = @{
        Name = "glueetl"
        # NOTA: Aqui referenciamos el archivo correcto "laptops_analytics_so.py"
        ScriptLocation = "s3://$env:BUCKET_NAME/scripts/laptops_analytics_so.py"
        PythonVersion = "3"
    }
    DefaultArguments = @{
        "--database" = "laptops_db"
        "--table" = "laptops_json"
        "--output_path" = "s3://$env:BUCKET_NAME/processed/laptops_by_opsys/"
        "--enable-continuous-cloudwatch-log" = "true"
        "--spark-event-logs-path" = "s3://$env:BUCKET_NAME/logs/"
    }
    GlueVersion = "4.0"
    NumberOfWorkers = 2
    WorkerType = "G.1X"
}
$jobOsConfig | ConvertTo-Json -Depth 5 | Out-File "job_os.json" -Encoding ASCII

aws glue create-job --cli-input-json file://job_os.json 2>$null
if (-not $?) { aws glue update-job --job-name laptops-analytics-opsys --job-update file://job_os.json >$null }
Remove-Item "job_os.json"

# --- 7. FINALIZACION ---

Write-Host "Infraestructura desplegada correctamente" -ForegroundColor Green
Write-Host "------------------------------------------------"
Write-Host "Pasos siguientes:"
Write-Host "1. Instala librerias: uv add boto3 loguru"
Write-Host "2. Ejecutar 'uv run kinesis.py' para enviar datos."
Write-Host "3. Espera 2 minutos."
Write-Host "4. Comprobar dentro de AWS Glue."
Write-Host "5. Ejecuta los Jobs 'laptops-analytics-brand' y 'laptops-analytics-opsys'."