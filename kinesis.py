import boto3
import json
import time
from loguru import logger

# CONFIGURACIÓN
STREAM_NAME = 'energy-stream' # Mantenemos el nombre creado por deploy.ps1
REGION = 'us-east-1'
INPUT_FILE = 'datos.json'

kinesis = boto3.client('kinesis', region_name=REGION)

def load_data(file_path):
    with open(file_path, 'r', encoding='utf-8') as f:
        return json.load(f)

def run_producer():
    laptops = load_data(INPUT_FILE)
    records_sent = 0
    
    logger.info(f"Iniciando transmisión de {len(laptops)} laptops al stream: {STREAM_NAME}...")
    
    for laptop in laptops:
        # Extraemos campos clave para el log
        laptop_id = laptop.get('laptop_ID')
        company = laptop.get('Company')
        price = laptop.get('Price_euros')
        
        # Enviar a Kinesis
        try:
            response = kinesis.put_record(
                StreamName=STREAM_NAME,
                Data=json.dumps(laptop), # Enviamos el objeto laptop entero
                PartitionKey=str(company) # Agrupar shards por marca (Apple, Dell, etc.)
            )
            
            records_sent += 1
            logger.info(f"Enviado ID:{laptop_id} ({company}) - {price}€ | Shard: {response['ShardId'][-5:]}")
            
            # Pequeña pausa para ver el efecto streaming
            time.sleep(0.2)
            
        except Exception as e:
            logger.error(f"Error enviando laptop {laptop_id}: {e}")

    logger.info(f"Fin de la transmisión. Total registros enviados: {records_sent}")

if __name__ == '__main__':
    run_producer()