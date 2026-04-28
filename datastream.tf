# ============================================================
# Datastream: Oracle source → Pub/Sub destination
# Latencia objetivo: 1-3 segundos de propagación
# ============================================================

# Recuperar password de Secret Manager
data "google_secret_manager_secret_version" "oracle_password" {
  secret = var.oracle_password_secret_id
}

# ============================================================
# Connection profile: Oracle source
# ============================================================
resource "google_datastream_connection_profile" "oracle_source" {
  display_name          = "${local.prefix}-oracle-source"
  location              = var.region
  connection_profile_id = "${local.prefix}-oracle-src"

  oracle_profile {
    hostname             = var.oracle_host
    port                 = var.oracle_port
    username             = var.oracle_username
    password             = data.google_secret_manager_secret_version.oracle_password.secret_data
    database_service     = var.oracle_service_name

    # Para Oracle 19c+ con LogMiner mejorado, descomenta:
    # connection_attributes = {
    #   "oracle_asm" = "false"
    # }
  }

  private_connectivity {
    private_connection = google_datastream_private_connection.oracle_psc.id
  }
}

# ============================================================
# Connection profile: GCS destination (intermedio para fan-out)
# Datastream escribe Avro a GCS, luego un job Dataflow lee desde ahí
# Esta arquitectura permite replay y fan-out limpio
# ============================================================
resource "google_storage_bucket" "datastream_landing" {
  name                        = "${var.project_id}-${local.prefix}-datastream-landing"
  location                    = var.region
  force_destroy               = false
  uniform_bucket_level_access = true

  versioning {
    enabled = false
  }

  lifecycle_rule {
    condition {
      age = 7  # Retención corta - los datos ya están en BQ y AlloyDB
    }
    action {
      type = "Delete"
    }
  }

  # Notify Pub/Sub on new files - así Dataflow procesa con baja latencia
  # (alternativa: Storage Notifications via Pub/Sub topic)
}

resource "google_pubsub_topic" "gcs_notifications" {
  name = "${local.prefix}-gcs-notifications"

  message_retention_duration = "86400s"  # 1 día
}

resource "google_storage_notification" "datastream_to_pubsub" {
  bucket         = google_storage_bucket.datastream_landing.name
  payload_format = "JSON_API_V1"
  topic          = google_pubsub_topic.gcs_notifications.id
  event_types    = ["OBJECT_FINALIZE"]

  depends_on = [google_pubsub_topic_iam_binding.gcs_publisher]
}

# Permitir a GCS publicar a Pub/Sub
data "google_storage_project_service_account" "gcs_account" {
}

resource "google_pubsub_topic_iam_binding" "gcs_publisher" {
  topic = google_pubsub_topic.gcs_notifications.id
  role  = "roles/pubsub.publisher"
  members = [
    "serviceAccount:${data.google_storage_project_service_account.gcs_account.email_address}",
  ]
}

resource "google_datastream_connection_profile" "gcs_dest" {
  display_name          = "${local.prefix}-gcs-dest"
  location              = var.region
  connection_profile_id = "${local.prefix}-gcs-dest"

  gcs_profile {
    bucket    = google_storage_bucket.datastream_landing.name
    root_path = "/cdc"
  }
}

# ============================================================
# Stream: el corazón de Datastream
# ============================================================
resource "google_datastream_stream" "oracle_to_gcs" {
  display_name = "${local.prefix}-oracle-stream"
  location     = var.region
  stream_id    = "${local.prefix}-oracle-stream"

  source_config {
    source_connection_profile = google_datastream_connection_profile.oracle_source.id

    oracle_source_config {
      # CRÍTICO para latencia: usar LogMiner directamente vs Binary Reader
      # LogMiner: más compatible, latencia ~1-2s típica
      # Binary Reader (19c+): latencia menor pero requiere setup adicional

      include_objects {
        dynamic "oracle_schemas" {
          for_each = distinct([for t in local.oracle_tables : t.schema])
          content {
            schema = oracle_schemas.value
            oracle_tables {
              dynamic "oracle_tables" {
                for_each = [for t in local.oracle_tables : t if t.schema == oracle_schemas.value]
                content {
                  table = oracle_tables.value.table
                }
              }
            }
          }
        }
      }

      # Tamaño máximo de chunks - menor = menor latencia, más overhead
      max_concurrent_cdc_tasks      = 5
      max_concurrent_backfill_tasks = 12
    }
  }

  destination_config {
    destination_connection_profile = google_datastream_connection_profile.gcs_dest.id

    gcs_destination_config {
      path                   = "/cdc"
      file_rotation_mb       = 5      # Archivos pequeños = menor latencia (default 50)
      file_rotation_interval = "15s"  # Rota cada 15s para baja latencia (default 60s)

      avro_file_format {}
    }
  }

  # Backfill inicial automático para todas las tablas
  backfill_all {
  }

  # Mantén estados consistentes con Datastream
  desired_state = "RUNNING"
}
