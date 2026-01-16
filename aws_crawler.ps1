# 1. Asegurar variables de entorno
if (-not $env:BUCKET_NAME) { $env:BUCKET_NAME = "datalake-laptops-098189193517" }
if (-not $env:ROLE_ARN) { $env:ROLE_ARN = "arn:aws:iam::098189193517:role/LabRole" }

# 2. Definir la configuracion del Crawler
$resultsCrawler = @{
    Name = "laptops-processed-crawler"
    Role = "$env:ROLE_ARN"
    DatabaseName = "laptops_db"
    Targets = @{ S3Targets = @( 
        @{ Path = "s3://$env:BUCKET_NAME/processed/laptops_by_brand/" },
        @{ Path = "s3://$env:BUCKET_NAME/processed/laptops_by_opsys/" } 
    )}
}

# 3. Guardar JSON temporal y crear Crawler
$resultsCrawler | ConvertTo-Json -Depth 5 | Out-File "glue_results_crawler.json" -Encoding ASCII
aws glue create-crawler --cli-input-json file://glue_results_crawler.json

# 4. Arrancar el Crawler
Write-Host "Iniciando crawler..." -ForegroundColor Green
aws glue start-crawler --name laptops-processed-crawler

# 5. Limpieza
Remove-Item "glue_results_crawler.json"