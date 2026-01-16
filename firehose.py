import json
import base64
import datetime

def lambda_handler(event, context):
    output = []
    
    for record in event['records']:
        try:
            # 1. Decodificar entrada de Kinesis
            payload = base64.b64decode(record['data']).decode('utf-8')
            data_json = json.loads(payload)
            
            # 2. Aniadir metadatos de procesamiento (Timestamp)
            processing_time = datetime.datetime.now(datetime.timezone.utc)
            data_json['processed_at'] = processing_time.isoformat()
            
            # 3. Preparar Partition Key para S3 (YYYY-MM-DD)
            partition_date = processing_time.strftime('%Y-%m-%d')
            
            # 4. Re-codificar para Firehose (Debe terminar en salto de linea para JSON Lines)
            output_payload = json.dumps(data_json) + '\n'
            
            output_record = {
                'recordId': record['recordId'],
                'result': 'Ok',
                'data': base64.b64encode(output_payload.encode('utf-8')).decode('utf-8'),
                'metadata': {
                    'partitionKeys': {
                        'processing_date': partition_date
                    }
                }
            }
            output.append(output_record)
            
        except Exception as e:
            # Si falla un registro, se marca como failed pero no se detiene todo el lote
            print(f"Error processing record: {e}")
            output.append({
                'recordId': record['recordId'],
                'result': 'ProcessingFailed',
                'data': record['data']
            })
    
    return {'records': output}