"""
Pipeline de Dataflow: lee notificaciones de Pub/Sub sobre archivos Avro
nuevos en GCS (escritos por Datastream), los parsea, y hace upsert
idempotente a AlloyDB. También publica al topic CDC events para fan-out.

Latencia objetivo: 1-3 segundos desde Datastream a AlloyDB.

Optimizaciones críticas para baja latencia:
- Triggering frequency 1-5s (configurable)
- Batches pequeños (100 rows) para no esperar a llenar buffer
- Connection pooling por worker (un pool, no una conn por DoFn call)
- Prepared statements para reducir round-trips
- Streaming Engine habilitado (en config Dataflow)
"""

import json
import logging
import os
from typing import Any, Dict, Iterable, List, Optional, Tuple

import apache_beam as beam
from apache_beam.io import fileio
from apache_beam.options.pipeline_options import (
    PipelineOptions,
    StandardOptions,
    GoogleCloudOptions,
    WorkerOptions,
)
from apache_beam.transforms.window import FixedWindows
from apache_beam.utils.windowed_value import WindowedValue
from fastavro import reader as avro_reader
from google.cloud import secretmanager
import psycopg2
from psycopg2.extras import execute_batch
from psycopg2.pool import ThreadedConnectionPool

# ============================================================
# Pipeline options
# ============================================================
class CdcServingOptions(PipelineOptions):
    @classmethod
    def _add_argparse_args(cls, parser):
        parser.add_value_provider_argument(
            "--gcs_notifications_subscription",
            type=str,
            help="Pub/Sub subscription que recibe notificaciones de GCS",
        )
        parser.add_value_provider_argument(
            "--cdc_events_topic", type=str, help="Topic destino para CDC events"
        )
        parser.add_value_provider_argument(
            "--alloydb_writer_secret",
            type=str,
            help="Secret Manager secret con connection string del primary",
        )
        parser.add_value_provider_argument(
            "--alloydb_password_secret",
            type=str,
            help="Secret Manager secret con password del usuario dataflow_writer",
        )
        parser.add_value_provider_argument(
            "--dlq_topic", type=str, help="Topic DLQ"
        )
        parser.add_value_provider_argument(
            "--triggering_frequency_seconds",
            type=int,
            default=1,
            help="Cada cuántos segundos triggear el procesamiento batch",
        )
        parser.add_value_provider_argument(
            "--upsert_batch_size",
            type=int,
            default=100,
            help="Tamaño máximo de batch para upsert a AlloyDB",
        )


# ============================================================
# Mapping: tabla Oracle → función de upsert en AlloyDB
# Mantén alineado con alloydb/schema.sql
# ============================================================
TABLE_MAPPINGS = {
    "CUSTOMERS": {
        "alloydb_table": "customers",
        "primary_key": "CUSTOMER_ID",
        "columns": [
            ("CUSTOMER_ID", "customer_id", "bigint"),
            ("EMAIL", "email", "varchar"),
            ("PHONE", "phone", "varchar"),
            ("FIRST_NAME", "first_name", "varchar"),
            ("LAST_NAME", "last_name", "varchar"),
            ("COUNTRY_CODE", "country_code", "char"),
            ("CREATED_AT", "created_at", "timestamptz"),
            ("UPDATED_AT", "updated_at", "timestamptz"),
        ],
    },
    "ORDERS": {
        "alloydb_table": "orders",
        "primary_key": "ORDER_ID",
        "columns": [
            ("ORDER_ID", "order_id", "bigint"),
            ("CUSTOMER_ID", "customer_id", "bigint"),
            ("ORDER_STATUS", "order_status", "varchar"),
            ("TOTAL_AMOUNT", "total_amount", "numeric"),
            ("CURRENCY", "currency", "char"),
            ("PLACED_AT", "placed_at", "timestamptz"),
            ("UPDATED_AT", "updated_at", "timestamptz"),
        ],
    },
    "ORDER_ITEMS": {
        "alloydb_table": "order_items",
        "primary_key": "ITEM_ID",
        "columns": [
            ("ITEM_ID", "item_id", "bigint"),
            ("ORDER_ID", "order_id", "bigint"),
            ("PRODUCT_ID", "product_id", "bigint"),
            ("QUANTITY", "quantity", "integer"),
            ("UNIT_PRICE", "unit_price", "numeric"),
        ],
    },
}


# ============================================================
# DoFn: parsea notificación de GCS y descarga el Avro
# ============================================================
class ParseGcsNotification(beam.DoFn):
    """Recibe el JSON de Pub/Sub (notificación de GCS) y emite la URI."""

    def process(self, element: bytes) -> Iterable[str]:
        try:
            notification = json.loads(element.decode("utf-8"))
            bucket = notification["bucket"]
            name = notification["name"]
            # Solo archivos .avro que vengan del path de Datastream
            if not name.endswith(".avro") or not name.startswith("cdc/"):
                return
            uri = f"gs://{bucket}/{name}"
            yield uri
        except Exception as e:
            logging.exception(f"Error parseando notificación: {e}")
            # No propagamos a DLQ aquí porque puede ser una notificación válida
            # de un objeto que no nos interesa


# ============================================================
# DoFn: lee el archivo Avro y emite eventos CDC
# ============================================================
class ReadAvroFile(beam.DoFn):
    """Lee un archivo Avro de GCS y emite cada record como dict."""

    def setup(self):
        from google.cloud import storage

        self.storage_client = storage.Client()

    def process(self, gcs_uri: str) -> Iterable[Dict[str, Any]]:
        try:
            # Parse gs://bucket/path
            assert gcs_uri.startswith("gs://")
            without_prefix = gcs_uri[5:]
            bucket_name, _, blob_path = without_prefix.partition("/")

            bucket = self.storage_client.bucket(bucket_name)
            blob = bucket.blob(blob_path)

            with blob.open("rb") as f:
                for record in avro_reader(f):
                    yield record
        except Exception as e:
            logging.exception(f"Error leyendo {gcs_uri}: {e}")
            yield beam.pvalue.TaggedOutput(
                "errors", {"uri": gcs_uri, "error": str(e)}
            )


# ============================================================
# DoFn: convierte el record Avro de Datastream a un evento CDC normalizado
# ============================================================
class NormalizeDatastreamEvent(beam.DoFn):
    """
    Datastream emite Avro con esta estructura:
    {
      'source_metadata': {
        'schema': 'APP_SCHEMA',
        'table': 'CUSTOMERS',
        'change_type': 'INSERT' | 'UPDATE-INSERT' | 'UPDATE-DELETE' | 'DELETE',
        'scn': long,
        'source_timestamp': long (millis)
      },
      'payload': {  # contiene los valores de las columnas
        'CUSTOMER_ID': 12345,
        'EMAIL': '...',
        ...
      }
    }
    """

    def process(self, record: Dict[str, Any]) -> Iterable[Dict[str, Any]]:
        try:
            metadata = record.get("source_metadata", {})
            payload = record.get("payload", {})

            schema = metadata.get("schema")
            table = metadata.get("table")
            change_type = metadata.get("change_type", "")

            if table not in TABLE_MAPPINGS:
                # Tabla no configurada - skip silenciosamente
                return

            # Normalizar change_type a INSERT/UPDATE/DELETE
            if "INSERT" in change_type:
                op = "INSERT"
            elif "UPDATE" in change_type:
                op = "UPDATE"
            elif "DELETE" in change_type:
                op = "DELETE"
            else:
                logging.warning(f"Unknown change_type: {change_type}")
                return

            mapping = TABLE_MAPPINGS[table]
            pk_col = mapping["primary_key"]
            pk_value = payload.get(pk_col)
            if pk_value is None:
                logging.error(f"PK nulo en evento {table}: {record}")
                yield beam.pvalue.TaggedOutput("errors", record)
                return

            scn = metadata.get("scn", 0)
            source_ts_ms = metadata.get("source_timestamp", 0)

            yield {
                "table": table,
                "operation": op,
                "primary_key": str(pk_value),
                "scn": int(scn),
                "source_ts_ms": int(source_ts_ms),
                "payload": payload,
            }
        except Exception as e:
            logging.exception(f"Error normalizando: {e}")
            yield beam.pvalue.TaggedOutput("errors", record)


# ============================================================
# DoFn: upsert idempotente a AlloyDB con connection pool
# ============================================================
class UpsertToAlloyDB(beam.DoFn):
    """
    Hace upsert batch a AlloyDB. Connection pool por worker (no por bundle).
    El SCN se usa como guard para idempotencia: solo update si entrante es más nuevo.
    """

    def __init__(self, secret_id_provider, password_secret_provider):
        self.secret_id_provider = secret_id_provider
        self.password_secret_provider = password_secret_provider
        self.pool: Optional[ThreadedConnectionPool] = None

    def setup(self):
        """Llamado una vez por worker. Crea el connection pool."""
        secret_client = secretmanager.SecretManagerServiceClient()

        conn_secret = self.secret_id_provider.get()
        password_secret = self.password_secret_provider.get()

        # Connection string base
        conn_string = secret_client.access_secret_version(
            request={"name": f"{conn_secret}/versions/latest"}
        ).payload.data.decode("utf-8")

        # Password
        password = secret_client.access_secret_version(
            request={"name": f"{password_secret}/versions/latest"}
        ).payload.data.decode("utf-8")

        # Inyectar password en connection string
        # Format: postgresql://user@host:port/db?...
        conn_string_with_pass = conn_string.replace(
            "://dataflow_writer@", f"://dataflow_writer:{password}@"
        )

        # Pool: 5 conexiones por worker es suficiente para batches de 100 rows
        # Si subes el batch_size, sube también el pool
        self.pool = ThreadedConnectionPool(
            minconn=2,
            maxconn=5,
            dsn=conn_string_with_pass,
            connect_timeout=10,
            keepalives=1,
            keepalives_idle=30,
            keepalives_interval=10,
            keepalives_count=3,
        )
        logging.info("AlloyDB connection pool initialized")

    def teardown(self):
        if self.pool:
            self.pool.closeall()

    def process(
        self, batch: List[Dict[str, Any]]
    ) -> Iterable[Dict[str, Any]]:
        """Procesa un batch de eventos del mismo tipo de tabla."""
        if not batch:
            return

        table = batch[0]["table"]
        mapping = TABLE_MAPPINGS[table]
        alloydb_table = mapping["alloydb_table"]
        columns = mapping["columns"]

        # Construir query parametrizado
        col_names_pg = [c[1] for c in columns]
        placeholders = ",".join(["%s"] * (len(col_names_pg) + 4))  # +4 por cdc cols

        col_list = ", ".join(col_names_pg + ["cdc_scn", "cdc_op_ts", "is_deleted"])

        # ON CONFLICT clause con guard de SCN
        update_clause = ", ".join(
            [f"{c} = EXCLUDED.{c}" for c in col_names_pg]
            + [
                "cdc_scn = EXCLUDED.cdc_scn",
                "cdc_op_ts = EXCLUDED.cdc_op_ts",
                "is_deleted = EXCLUDED.is_deleted",
                "cdc_received_at = NOW()",
            ]
        )

        pk_pg = mapping["primary_key"].lower()  # asumimos snake_case en alloydb

        sql = f"""
            INSERT INTO {alloydb_table} ({col_list})
            VALUES ({placeholders})
            ON CONFLICT ({pk_pg}) DO UPDATE SET {update_clause}
            WHERE {alloydb_table}.cdc_scn < EXCLUDED.cdc_scn
        """

        # Construir filas
        rows = []
        for event in batch:
            payload = event["payload"]
            is_deleted = event["operation"] == "DELETE"
            row_values = [payload.get(c[0]) for c in columns]
            row_values.extend(
                [
                    event["scn"],
                    self._micros_to_dt(event["source_ts_ms"] * 1000),
                    is_deleted,
                ]
            )
            rows.append(row_values)

        # Ejecutar batch
        conn = self.pool.getconn()
        try:
            with conn.cursor() as cur:
                execute_batch(cur, sql, rows, page_size=len(rows))
            conn.commit()

            # Log lag para métricas
            for event in batch:
                lag_ms = self._compute_lag_ms(event["source_ts_ms"])
                logging.info(
                    json.dumps(
                        {
                            "metric": "e2e_lag_ms",
                            "table_name": table,
                            "lag_ms": lag_ms,
                        }
                    )
                )

            yield from batch

        except psycopg2.Error as e:
            conn.rollback()
            logging.exception(f"Error upserting a {alloydb_table}: {e}")
            for event in batch:
                yield beam.pvalue.TaggedOutput(
                    "errors",
                    {
                        "event": event,
                        "error": str(e),
                        "error_code": e.pgcode if hasattr(e, "pgcode") else None,
                    },
                )
        finally:
            self.pool.putconn(conn)

    @staticmethod
    def _micros_to_dt(micros: int):
        from datetime import datetime, timezone

        return datetime.fromtimestamp(micros / 1_000_000, tz=timezone.utc)

    @staticmethod
    def _compute_lag_ms(source_ts_ms: int) -> int:
        import time

        now_ms = int(time.time() * 1000)
        return now_ms - source_ts_ms


# ============================================================
# Pipeline
# ============================================================
def run():
    options = CdcServingOptions()
    options.view_as(StandardOptions).streaming = True

    cdc_opts = options.view_as(CdcServingOptions)

    with beam.Pipeline(options=options) as p:
        # 1. Lee notificaciones de GCS desde Pub/Sub
        notifications = (
            p
            | "ReadGcsNotifs"
            >> beam.io.ReadFromPubSub(
                subscription=cdc_opts.gcs_notifications_subscription
            )
            | "ParseNotif" >> beam.ParDo(ParseGcsNotification())
        )

        # 2. Lee cada archivo Avro y emite records
        records = notifications | "ReadAvro" >> beam.ParDo(ReadAvroFile()).with_outputs(
            "errors", main="main"
        )

        # 3. Normaliza al formato común
        normalized = records.main | "Normalize" >> beam.ParDo(
            NormalizeDatastreamEvent()
        ).with_outputs("errors", main="main")

        # 4. Agrupa en batches por tabla, con ventana corta para baja latencia
        batched = (
            normalized.main
            | "WithKey" >> beam.Map(lambda e: (e["table"], e))
            | "Window"
            >> beam.WindowInto(
                FixedWindows(cdc_opts.triggering_frequency_seconds.get())
            )
            | "GroupByTable" >> beam.GroupByKey()
            | "ToBatches"
            >> beam.FlatMap(
                lambda kv: _chunk(kv[1], cdc_opts.upsert_batch_size.get())
            )
        )

        # 5. Upsert a AlloyDB
        upserted = batched | "UpsertAlloyDB" >> beam.ParDo(
            UpsertToAlloyDB(
                cdc_opts.alloydb_writer_secret, cdc_opts.alloydb_password_secret
            )
        ).with_outputs("errors", main="main")

        # 6. Publica eventos exitosos al topic CDC events (para BQ y otros consumidores)
        _ = (
            upserted.main
            | "FormatForPubsub"
            >> beam.Map(lambda e: json.dumps(e, default=str).encode("utf-8"))
            | "PublishCdcEvents"
            >> beam.io.WriteToPubSub(topic=cdc_opts.cdc_events_topic)
        )

        # 7. Errores a DLQ
        all_errors = (
            (records.errors, normalized.errors, upserted.errors)
            | "FlattenErrors" >> beam.Flatten()
            | "FormatErrors"
            >> beam.Map(lambda e: json.dumps(e, default=str).encode("utf-8"))
            | "PublishDlq" >> beam.io.WriteToPubSub(topic=cdc_opts.dlq_topic)
        )


def _chunk(items, size):
    """Divide una lista en chunks del tamaño especificado."""
    items = list(items)
    for i in range(0, len(items), size):
        yield items[i : i + size]


if __name__ == "__main__":
    logging.getLogger().setLevel(logging.INFO)
    run()
