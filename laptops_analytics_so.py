import sys
import logging
from pyspark.context import SparkContext
from awsglue.context import GlueContext
from awsglue.utils import getResolvedOptions
from pyspark.sql.functions import col, avg, count, min as spark_min, max as spark_max
from awsglue.dynamicframe import DynamicFrame

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

def main():
    args = getResolvedOptions(sys.argv, ['database', 'table', 'output_path'])
    database = args['database']
    table = args['table']
    output_path = args['output_path']

    logger.info(f"Iniciando Analytics por OS. DB: {database}, Table: {table}")
    
    sc = SparkContext()
    glueContext = GlueContext(sc)
    spark = glueContext.spark_session

    dynamic_frame = glueContext.create_dynamic_frame.from_catalog(
        database=database,
        table_name=table
    )

    # --- CORRECCION DE TIPO DE DATO ---
    try:
        dynamic_frame = dynamic_frame.resolveChoice(specs = [('Price_euros','cast:double')])
    except:
        pass

    df = dynamic_frame.toDF()   
    if df.count() == 0:
        logger.warning("Sin datos.")
        return

    df = df.withColumn("Price_euros", col("Price_euros").cast("double"))
    
    # 2. LOGICA: Agregacion por OS
    agg_df = df.groupBy("OpSys") \
        .agg(
            count("laptop_ID").alias("cantidad_dispositivos"),
            avg("Price_euros").alias("coste_promedio"),
            spark_min("Price_euros").alias("coste_minimo"),
            spark_max("Price_euros").alias("coste_maximo")
        ) \
        .orderBy("coste_promedio", ascending=False)
    
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