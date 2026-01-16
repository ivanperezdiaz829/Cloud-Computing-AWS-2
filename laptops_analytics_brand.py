import sys
import logging
from pyspark.context import SparkContext
from awsglue.context import GlueContext
from awsglue.utils import getResolvedOptions
from pyspark.sql.functions import col, avg, count, max as spark_max, current_date
from awsglue.dynamicframe import DynamicFrame

# Configuracion de Logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

def main():
    args = getResolvedOptions(sys.argv, ['database', 'table', 'output_path'])
    database = args['database']
    table = args['table']
    output_path = args['output_path']
    
    logger.info(f"Iniciando Analytics por Marca. DB: {database}, Table: {table}")
    
    sc = SparkContext()
    glueContext = GlueContext(sc)
    spark = glueContext.spark_session
    
    # 1. Leer datos
    dynamic_frame = glueContext.create_dynamic_frame.from_catalog(
        database=database,
        table_name=table
    )
    
    # --- CORRECCION DE TIPO DE DATO (CHOICE) ---
    # Esto fuerza a que Price_euros sea tratado siempre como double, 
    # resolviendo la ambiguedad entre int y double.
    try:
        dynamic_frame = dynamic_frame.resolveChoice(specs = [('Price_euros','cast:double')])
    except:
        logger.warning("No se requirio resolveChoice o fallo, continuando...")

    df = dynamic_frame.toDF()
    
    if df.count() == 0:
        logger.warning("No se encontraron datos de laptops. Finalizando.")
        return

    # Asegurar cast final
    df = df.withColumn("Price_euros", col("Price_euros").cast("double"))

    # 2. LOGICA: Agregacion por MARCA
    agg_df = df.groupBy("Company") \
        .agg(
            count("laptop_ID").alias("total_modelos"),
            avg("Price_euros").alias("precio_promedio"),
            spark_max("Price_euros").alias("precio_mas_alto")
        ) \
        .withColumn("fecha_analisis", current_date()) \
        .orderBy("precio_promedio", ascending=False)
    
    # 3. Escribir resultados
    output_dynamic_frame = DynamicFrame.fromDF(agg_df, glueContext, "output")
    
    glueContext.write_dynamic_frame.from_options(
        frame=output_dynamic_frame,
        connection_type="s3",
        connection_options={ "path": output_path },
        format="parquet",
        format_options={"compression": "snappy"}
    )
    
    logger.info(f"Job completado.")

if __name__ == "__main__":
    main()