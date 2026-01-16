Write-Host "INICIANDO LIMPIEZA TOTAL (V2)..." -ForegroundColor Red

# --- PASO 0: RECUPERAR NOMBRE DEL BUCKET AUTOMATICAMENTE ---
# Esto evita fallos si cerraste la terminal y perdiste la variable $env:BUCKET_NAME
try {
    $env:ACCOUNT_ID = (aws sts get-caller-identity --query Account --output text).Trim()
    $env:BUCKET_NAME = "datalake-laptops-$($env:ACCOUNT_ID)"
    Write-Host "Cuenta detectada: $env:ACCOUNT_ID" -ForegroundColor Gray
    Write-Host "Bucket objetivo: $env:BUCKET_NAME" -ForegroundColor Gray
} catch {
    Write-Error "No se detectan credenciales AWS. Ejecuta 'aws configure' primero."
    exit 1
}

# --- 1. S3 (ELIMINACION FORZADA) ---
Write-Host "1. Eliminando Bucket S3..."
# El 2>$null oculta errores si el bucket ya no existe
aws s3 rb s3://$env:BUCKET_NAME --force 2>$null 

# --- 2. STREAMS (LO MAS CARO) ---
Write-Host "2. Eliminando Streams..."
aws firehose delete-delivery-stream --delivery-stream-name laptops-delivery-stream 2>$null
aws kinesis delete-stream --stream-name energy-stream 2>$null

# --- 3. GLUE (CRAWLERS, JOBS, DB) ---
Write-Host "3. Eliminando recursos Glue..."
aws glue delete-crawler --name laptops-raw-crawler 2>$null
aws glue delete-crawler --name laptops-processed-crawler 2>$null
aws glue delete-job --job-name laptops-analytics-brand 2>$null
aws glue delete-job --job-name laptops-analytics-opsys 2>$null

# Nota: Glue no deja borrar la DB si tiene tablas dentro. 
# Intentamos borrar las tablas primero (brute force simple)
aws glue delete-table --database-name laptops_db --name laptops_json 2>$null
aws glue delete-table --database-name laptops_db --name laptops_by_brand 2>$null
aws glue delete-table --database-name laptops_db --name laptops_by_opsys 2>$null
aws glue delete-database --name laptops_db 2>$null

# --- 4. LAMBDA ---
Write-Host "4. Eliminando Lambda..."
aws lambda delete-function --function-name laptops-firehose-lambda 2>$null

# --- 5. CLOUDWATCH LOGS (LIMPIEZA DE RASTROS) ---
Write-Host "5. Limpiando Logs residuales..."
# Esto borra los grupos de logs generados por tu Lambda y tus Jobs
aws logs delete-log-group --log-group-name "/aws/lambda/laptops-firehose-lambda" 2>$null
aws logs delete-log-group --log-group-name "/aws-glue/crawlers" 2>$null
aws logs delete-log-group --log-group-name "/aws-glue/jobs/laptops-analytics-brand" 2>$null
aws logs delete-log-group --log-group-name "/aws-glue/jobs/laptops-analytics-opsys" 2>$null

Write-Host "Limpieza completada - Cuenta limpia." -ForegroundColor Green