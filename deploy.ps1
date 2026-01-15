# --- 1. CONFIGURACIÓN ---
$env:AWS_REGION = "us-east-1"
# Obtener Account ID
try {
    $env:ACCOUNT_ID = (aws sts get-caller-identity --query Account --output text).Trim()
} catch {
    $env:ACCOUNT_ID = "098189193517"
}

$env:BUCKET_NAME = "datalake-laptops-$($env:ACCOUNT_ID)"

# Obtener Role ARN
try {
    $env:ROLE_ARN = (aws iam get-role --role-name LabRole --query 'Role.Arn' --output text).Trim()
} catch {
    Write-Error "No se pudo conectar a AWS. Revisa tus credenciales."
    exit 1
}

Write-Host "------------------------------------------------" -ForegroundColor Cyan
Write-Host "CONFIGURACIÓN:"
Write-Host "Bucket: $($env:BUCKET_NAME)"
Write-Host "Role:   $($env:ROLE_ARN)"
Write-Host "------------------------------------------------" -ForegroundColor Cyan

# --- 2. S3 & KINESIS ---

Write-Host "Creando Bucket..." -ForegroundColor Yellow
aws s3 mb s3://$env:BUCKET_NAME 2>$null

Write-Host "Subiendo estructura de carpetas..." -ForegroundColor Yellow
aws s3api put-object --bucket $env:BUCKET_NAME --key raw/
aws s3api put-object --bucket $env:BUCKET_NAME --key raw/laptops_json/
aws s3api put-object --bucket $env:BUCKET_NAME --key processed/
aws s3api put-object --bucket $env:BUCKET_NAME --key config/
aws s3api put-object --bucket $env:BUCKET_NAME --key scripts/
aws s3api put-object --bucket $env:BUCKET_NAME --key logs/
aws s3api put-object --bucket $env:BUCKET_NAME --key errors/

Write-Host "Creando Kinesis Stream..." -ForegroundColor Yellow
aws kinesis create-stream --stream-name energy-stream --shard-count 1 2>$null

# --- 3. LAMBDA ---

Write-Host "Desplegando Lambda..." -ForegroundColor Yellow

if (Test-Path "firehose.zip") { Remove-Item "firehose.zip" }
Compress-Archive -Path "firehose.py" -DestinationPath "firehose.zip"

aws lambda create-function `
    --function-name laptops-firehose-lambda `
    --runtime python3.12 `
    --role $env:ROLE_ARN `
    --handler firehose.lambda_handler `
    --zip-file fileb://firehose.zip `
    --timeout 60 `
    --memory-size 128 2>$null

if (-not $?) {
    Write-Host "Actualizando Lambda..." -ForegroundColor DarkYellow
    aws lambda update-function-code --function-name laptops-firehose-lambda --zip-file fileb://firehose.zip >$null
}
Start-Sleep -Seconds 5
$env:LAMBDA_ARN = (aws lambda get-function --function-name laptops-firehose-lambda --query 'Configuration.FunctionArn' --output text).Trim()

# --- 4. FIREHOSE ---

Write-Host "Creando Firehose..." -ForegroundColor Yellow

# Construir objeto PowerShell y convertir a JSON para evitar errores de sintaxis
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

Write-Host "Configurando Glue..." -ForegroundColor Yellow

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

aws glue start-crawler --name laptops-raw-crawler 2>$null

# --- 6. GLUE JOBS ---

Write-Host "Subiendo scripts y creando Jobs..." -ForegroundColor Yellow

aws s3 cp laptops_analytics_brand.py s3://$env:BUCKET_NAME/scripts/
aws s3 cp laptops_analytics_opsys.py s3://$env:BUCKET_NAME/scripts/

# Job 1: Analítica por MARCA
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
Remove-Item "job_brand.json"

# Job 2: Analítica por SO
$jobOsConfig = @{
    Name = "laptops-analytics-opsys"
    Role = "$env:ROLE_ARN"
    Command = @{
        Name = "glueetl"
        ScriptLocation = "s3://$env:BUCKET_NAME/scripts/laptops_analytics_opsys.py"
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
Remove-Item "job_os.json"

# --- 7. EJECUCIÓN ---
Write-Host "Iniciando Jobs..." -ForegroundColor Green
aws glue start-job-run --job-name laptops-analytics-brand
aws glue start-job-run --job-name laptops-analytics-opsys

Write-Host "¡Despliegue de Laptops Analytics Finalizado!" -ForegroundColor Green