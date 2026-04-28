# ============================================================
# Dataflow: pipeline que lee de GCS (vía Pub/Sub notifications)
# y escribe a AlloyDB y al topic CDC events
# ============================================================

# Service account dedicado para Dataflow workers
resource "google_service_account" "dataflow_sa" {
  account_id   = "${local.prefix}-dataflow-sa"
  display_name = "Dataflow CDC pipeline service account"
}

# Permisos mínimos requeridos
resource "google_project_iam_member" "dataflow_worker" {
  project = var.project_id
  role    = "roles/dataflow.worker"
  member  = "serviceAccount:${google_service_account.dataflow_sa.email}"
}

resource "google_project_iam_member" "dataflow_storage" {
  project = var.project_id
  role    = "roles/storage.objectAdmin"
  member  = "serviceAccount:${google_service_account.dataflow_sa.email}"
}

resource "google_project_iam_member" "dataflow_pubsub_publisher" {
  project = var.project_id
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${google_service_account.dataflow_sa.email}"
}

resource "google_project_iam_member" "dataflow_pubsub_subscriber" {
  project = var.project_id
  role    = "roles/pubsub.subscriber"
  member  = "serviceAccount:${google_service_account.dataflow_sa.email}"
}

resource "google_project_iam_member" "dataflow_secret_accessor" {
  project = var.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.dataflow_sa.email}"
}

resource "google_project_iam_member" "dataflow_alloydb" {
  project = var.project_id
  role    = "roles/alloydb.client"
  member  = "serviceAccount:${google_service_account.dataflow_sa.email}"
}

# ============================================================
# Bucket para staging y temp de Dataflow
# ============================================================
resource "google_storage_bucket" "dataflow_temp" {
  name                        = "${var.project_id}-${local.prefix}-dataflow-temp"
  location                    = var.region
  force_destroy               = true
  uniform_bucket_level_access = true

  lifecycle_rule {
    condition {
      age = 1  # Temp files no necesitan persistencia
    }
    action {
      type = "Delete"
    }
  }
}

# ============================================================
# Job: Pub/Sub (de GCS notifications) → AlloyDB + Pub/Sub events topic
# ============================================================
resource "google_dataflow_flex_template_job" "serving" {
  provider                = google-beta
  name                    = "${local.prefix}-serving-job"
  container_spec_gcs_path = var.dataflow_image_uri
  region                  = var.region

  parameters = {
    # Inputs
    gcs_notifications_subscription = google_pubsub_subscription.gcs_notifications_sub.name
    cdc_events_topic               = google_pubsub_topic.cdc_events.name

    # AlloyDB
    alloydb_writer_secret = google_secret_manager_secret.alloydb_writer_connection.id
    alloydb_password_secret = var.alloydb_password_secret_id

    # DLQ
    dlq_topic = google_pubsub_topic.dlq_serving.name

    # CRÍTICO para latencia: triggering interval bajo
    # 1s = procesa cada segundo, mayor costo pero menor latencia
    # 5s = balance razonable
    triggering_frequency_seconds = "1"

    # Tamaño de batch para upserts a AlloyDB
    # Pequeño = menor latencia, mayor overhead
    # Grande = mayor throughput, mayor latencia
    upsert_batch_size = "100"
  }

  on_delete                 = "drain"
  enable_streaming_engine   = true  # CRÍTICO: streaming engine reduce latencia
  service_account_email     = google_service_account.dataflow_sa.email
  network                   = google_compute_network.vpc.name
  subnetwork                = "regions/${var.region}/subnetworks/${google_compute_subnetwork.dataflow.name}"
  ip_configuration          = "WORKER_IP_PRIVATE"  # Sin IP pública = más seguro y rápido
  temp_location             = "gs://${google_storage_bucket.dataflow_temp.name}/temp"
  staging_location          = "gs://${google_storage_bucket.dataflow_temp.name}/staging"
  machine_type              = var.dataflow_machine_type
  max_workers               = var.dataflow_max_workers
  num_workers               = 2  # Empezar con 2 para baja latencia desde el inicio

  # Etiquetas para tracking de costos
  labels = {
    environment = var.environment
    pipeline    = "cdc-serving"
  }

  depends_on = [
    google_project_iam_member.dataflow_worker,
    google_project_iam_member.dataflow_pubsub_subscriber,
    google_project_iam_member.dataflow_alloydb,
  ]
}

# Subscription para que Dataflow lea las notificaciones de GCS
resource "google_pubsub_subscription" "gcs_notifications_sub" {
  name  = "${local.prefix}-gcs-notif-sub"
  topic = google_pubsub_topic.gcs_notifications.name

  ack_deadline_seconds = 60

  retry_policy {
    minimum_backoff = "1s"
    maximum_backoff = "60s"
  }

  message_retention_duration = "86400s"
}
