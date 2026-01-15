```bash
export AWS_REGION="us-east-1"
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export BUCKET_NAME="datalake-consumo-energetico-${ACCOUNT_ID}"
export ROLE_ARN=$(aws iam get-role --role-name LabRole --query 'Role.Arn' --output text)
export LAMBDA_ARN=$(aws lambda get-function --function-name energy-firehose-lambda --query 'Configuration.FunctionArn' --output text)

echo "Usando Bucket: $BUCKET_NAME y Role: $ROLE_ARN"
```

**Windows (PowerShell):**

```powershell
$env:AWS_REGION="us-east-1"
$env:ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
$env:BUCKET_NAME="datalake-consumo-energetico-$($env:ACCOUNT_ID)"
$env:ROLE_ARN=$(aws iam get-role --role-name LabRole --query 'Role.Arn' --output text)
```

--- Kinesis & S3


# Crear el bucket
aws s3 mb s3://$BUCKET_NAME

# Crear carpetas (objetos vacíos con / al final)
aws s3api put-object --bucket $BUCKET_NAME --key raw/
aws s3api put-object --bucket $BUCKET_NAME --key raw/energy_consumption_five_minutes/
aws s3api put-object --bucket $BUCKET_NAME --key processed/
aws s3api put-object --bucket $BUCKET_NAME --key config/
aws s3api put-object --bucket $BUCKET_NAME --key scripts/
aws s3api put-object --bucket $BUCKET_NAME --key queries/
aws s3api put-object --bucket $BUCKET_NAME --key scripts/
aws s3api put-object --bucket $BUCKET_NAME --key errors/


aws kinesis create-stream --stream-name energy-stream --shard-count 1



--- FIREHOSE

zip firehose.zip firehose.py

aws lambda create-function \
    --function-name energy-firehose-lambda \
    --runtime python3.12 \
    --role $ROLE_ARN \
    --handler firehose.lambda_handler \
    --zip-file fileb://firehose.zip \
    --timeout 60 \
    --memory-size 128

aws lambda update-function-code \
    --function-name energy-firehose-lambda \
    --zip-file fileb://firehose.zip

export AWS_REGION="us-east-1"
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export BUCKET_NAME="datalake-consumo-energetico-${ACCOUNT_ID}"
export ROLE_ARN=$(aws iam get-role --role-name LabRole --query 'Role.Arn' --output text)
export LAMBDA_ARN=$(aws lambda get-function --function-name energy-firehose-lambda --query 'Configuration.FunctionArn' --output text)


aws firehose create-delivery-stream \
    --delivery-stream-name energy-delivery-stream \
    --delivery-stream-type KinesisStreamAsSource \
    --kinesis-stream-source-configuration "KinesisStreamARN=arn:aws:kinesis:$AWS_REGION:$ACCOUNT_ID"":stream/energy-stream,RoleARN=$ROLE_ARN" \
    --extended-s3-destination-configuration '{
        "BucketARN": "arn:aws:s3:::'"$BUCKET_NAME"'",
        "RoleARN": "'"$ROLE_ARN"'",
        "Prefix": "raw/energy_consumption_five_minutes/processing_date=!{partitionKeyFromLambda:processing_date}/",
        "ErrorOutputPrefix": "errors/!{firehose:error-output-type}/",
        "BufferingHints": {
            "SizeInMBs": 64,
            "IntervalInSeconds": 60
        },
        "DynamicPartitioningConfiguration": {
            "Enabled": true,
            "RetryOptions": {
                "DurationInSeconds": 300
            }
        },
        "ProcessingConfiguration": {
            "Enabled": true,
            "Processors": [
                {
                    "Type": "Lambda",
                    "Parameters": [
                        {
                            "ParameterName": "LambdaArn",
                            "ParameterValue": "'"$LAMBDA_ARN"'"
                        },
                        {
                            "ParameterName": "BufferSizeInMBs",
                            "ParameterValue": "1"
                        },
                        {
                            "ParameterName": "BufferIntervalInSeconds",
                            "ParameterValue": "60"
                        }
                    ]
                }
            ]
        }
    }'




--- GLUE

aws glue create-database --database-input "{\"Name\":\"energy_db\"}"

aws glue create-crawler \
    --name energy-raw-crawler \
    --role $ROLE_ARN \
    --database-name energy_db \
    --targets "{\"S3Targets\": [{\"Path\": \"s3://$BUCKET_NAME/raw/energy_consumption_five_minutes\"}]}"

aws glue start-crawler --name energy-raw-crawler


--- GLUE ETL

aws s3 cp energy_aggregation_daily.py s3://$BUCKET_NAME/scripts/
aws s3 cp energy_aggregation_monthly.py s3://$BUCKET_NAME/scripts/

export DATABASE="energy_db"
export TABLE="energy_consumption_five_minutes"
export DAILY_OUTPUT="s3://$BUCKET_NAME/processed/energy_consumption_daily/"
export MONTHLY_OUTPUT="s3://$BUCKET_NAME/processed/energy_consumption_monthly/"
export ROLE_ARN=$(aws iam get-role --role-name LabRole --query 'Role.Arn' --output text)

aws glue create-job \
    --name energy-monthly-aggregation \
    --role $ROLE_ARN \
    --command '{
        "Name": "glueetl",
        "ScriptLocation": "s3://'"$BUCKET_NAME"'/scripts/energy_aggregation_monthly.py",
        "PythonVersion": "3"
    }' \
    --default-arguments '{
        "--database": "'"$DATABASE"'",
        "--table": "'"$TABLE"'",
        "--output_path": "s3://'"$BUCKET_NAME"'/processed/energy_consumption_monthly/",
        "--enable-continuous-cloudwatch-log": "true",
        "--spark-event-logs-path": "s3://'"$BUCKET_NAME"'/logs/"
    }' \
    --glue-version "4.0" \
    --number-of-workers 2 \
    --worker-type "G.1X"

aws glue create-job \
    --name energy-daily-aggregation \
    --role $ROLE_ARN \
    --command '{
        "Name": "glueetl",
        "ScriptLocation": "s3://'"$BUCKET_NAME"'/scripts/energy_aggregation_daily.py",
        "PythonVersion": "3"
    }' \
    --default-arguments '{
        "--database": "'"$DATABASE"'",
        "--table": "'"$TABLE"'",
        "--output_path": "s3://'"$BUCKET_NAME"'/processed/energy_consumption_daily/",
        "--enable-continuous-cloudwatch-log": "true",
        "--spark-event-logs-path": "s3://'"$BUCKET_NAME"'/logs/"
    }' \
    --glue-version "4.0" \
    --number-of-workers 2 \
    --worker-type "G.1X"


aws glue start-job-run --job-name energy-daily-aggregation

aws glue start-job-run --job-name energy-monthly-aggregation

# Ver estado
aws glue get-job-runs --job-name energy-daily-aggregation --max-items 1
aws glue get-job-runs --job-name energy-monthly-aggregation --max-items 1