# EJECUTAR SOLO UNA VEZ SI NO SE TIENE EL ENVIRONMENT
# ======================================================
# uv init
# uv add boto3
# uv add loguru
# uv venv
# ======================================================

# Activar Environment
.venv\Scripts\activate

# RELLENAR ANTES DE EJECUTAR
# ======================================================
# $env:AWS_ACCESS_KEY_ID="PONER DATOS DE AWS"
# $env:AWS_SECRET_ACCESS_KEY="PONER DATOS DE AWS"
# $env:AWS_SESSION_TOKEN="PONER DATOS DE AWS"
# ======================================================

# Comprobar que AWS responde a la cuenta puesta con las variables, si devuelve un JSON con la cuenta y el Arn continuar
aws sts get-caller-identity

# PASO 1: Desplegar la infraestructura
# ======================================================
.\deploy.ps1

# PASO 2: Simular el envio de datos a Kinesis
# ======================================================
uv run kinesis.py

# PASO 3: Iniciar el Crawler de Glue para catalogar datos en bruto
# ======================================================
aws glue start-crawler --name laptops-raw-crawler
# Ejecutar para ver el estado (termina cuando READY)
aws glue get-crawler --name laptops-raw-crawler --query "Crawler.State"

# PASO 4: Ejecutar los JOBS de Glue para transformar y almacenar datos procesados
# ======================================================
aws glue start-job-run --job-name laptops-analytics-brand
aws glue start-job-run --job-name laptops-analytics-opsys
# Ejecutar para ver el estado (termina cuando READY)
aws glue get-job-runs --job-name laptops-analytics-brand --max-results 1 --query "JobRuns[0].JobRunState"
aws glue get-job-runs --job-name laptops-analytics-opsys --max-results 1 --query "JobRuns[0].JobRunState"

# PASO 5: Iniciar el Crawler de Glue para catalogar datos procesados
# ======================================================
.\aws_crawler.ps1

# PASO 6: Consultar AWS Athena y realizar varias sentencias SQL

# PASO 7: Limpiar la cuenta de recursos para evitar costes (comprobar en AWS que se han borrado correctamente)
# ======================================================
.\clean.ps1



