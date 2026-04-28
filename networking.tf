# ============================================================
# Pub/Sub: backbone de fan-out
# ============================================================

# Topic principal: eventos CDC que vienen de GCS via Dataflow
resource "google_pubsub_topic" "cdc_events" {
  name = "${local.prefix}-events"

  message_retention_duration = "604800s"  # 7 días - permite replay

  message_storage_policy {
    allowed_persistence_regions = [var.region]
  }

  schema_settings {
    schema   = google_pubsub_schema.cdc_event_schema.id
    encoding = "JSON"
  }

  depends_on = [google_pubsub_schema.cdc_event_schema]
}

# Schema: documenta y valida la estructura de eventos CDC
# (la valida Pub/Sub al publicar, no en consume)
resource "google_pubsub_schema" "cdc_event_schema" {
  name = "${local.prefix}-cdc-schema"
  type = "AVRO"

  definition = jsonencode({
    type      = "record"
    name      = "CdcEvent"
    namespace = "com.dualsink.cdc"
    fields = [
      { name = "table_name", type = "string" },
      { name = "operation", type = { type = "enum", name = "Op", symbols = ["INSERT", "UPDATE", "DELETE"] } },
      { name = "primary_key", type = "string" },  # serializado como JSON string para PKs compuestas
      { name = "before_data", type = ["null", "string"], default = null },  # JSON
      { name = "after_data", type = ["null", "string"], default = null },   # JSON
      { name = "cdc_scn", type = "long" },
      { name = "cdc_op_ts", type = { type = "long", logicalType = "timestamp-micros" } },
      { name = "source_metadata", type = ["null", "string"], default = null },
    ]
  })
}

# ============================================================
# Subscription: Dataflow serving (hot tier)
# ============================================================
resource "google_pubsub_subscription" "serving" {
  name  = "${local.prefix}-serving-sub"
  topic = google_pubsub_topic.cdc_events.name

  # CRÍTICO para correctness: ordering por PK
  enable_message_ordering = true

  # CRÍTICO para latencia: deadline corto para que Dataflow procese rápido
  ack_deadline_seconds = 30

  # Retención: si Dataflow muere, no perdemos eventos por un rato
  message_retention_duration = "86400s"  # 1 día

  # Exactly-once: previene duplicados a costa de un poco de latencia
  enable_exactly_once_delivery = true

  expiration_policy {
    ttl = ""  # Nunca expira
  }

  retry_policy {
    minimum_backoff = "1s"   # Reintenta rápido para mantener latencia baja
    maximum_backoff = "60s"
  }

  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.dlq_serving.id
    max_delivery_attempts = 5
  }
}

# ============================================================
# Subscription: BigQuery analytics
# Datastream tiene sink directo a BQ, pero también podemos consumir
# del topic con un suscriptor BQ subscription (más simple).
# Aquí usamos BQ Subscription que escribe directo a BigQuery.
# ============================================================
resource "google_pubsub_subscription" "analytics" {
  name  = "${local.prefix}-analytics-sub"
  topic = google_pubsub_topic.cdc_events.name

  # Para analytics no necesitamos ordering estricto
  enable_message_ordering = false

  ack_deadline_seconds = 60

  bigquery_config {
    table            = "${var.project_id}.staging.cdc_raw_events"
    use_table_schema = false
    write_metadata   = true
    drop_unknown_fields = true
  }

  message_retention_duration = "86400s"

  retry_policy {
    minimum_backoff = "10s"
    maximum_backoff = "600s"
  }

  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.dlq_analytics.id
    max_delivery_attempts = 10
  }

  depends_on = [
    google_pubsub_topic_iam_binding.bq_sub_publisher,
    google_pubsub_topic_iam_binding.bq_sub_metadata,
  ]
}

# DLQs
resource "google_pubsub_topic" "dlq_serving" {
  name                       = "${local.prefix}-dlq-serving"
  message_retention_duration = "604800s"
}

resource "google_pubsub_topic" "dlq_analytics" {
  name                       = "${local.prefix}-dlq-analytics"
  message_retention_duration = "604800s"
}

resource "google_pubsub_subscription" "dlq_serving_inspect" {
  name                       = "${local.prefix}-dlq-serving-inspect"
  topic                      = google_pubsub_topic.dlq_serving.name
  ack_deadline_seconds       = 600
  message_retention_duration = "604800s"
}

resource "google_pubsub_subscription" "dlq_analytics_inspect" {
  name                       = "${local.prefix}-dlq-analytics-inspect"
  topic                      = google_pubsub_topic.dlq_analytics.name
  ack_deadline_seconds       = 600
  message_retention_duration = "604800s"
}

# ============================================================
# IAM para BQ Subscription
# ============================================================
data "google_project" "current" {
  project_id = var.project_id
}

# El service account de Pub/Sub necesita escribir a BQ
resource "google_project_iam_member" "pubsub_bq_writer" {
  project = var.project_id
  role    = "roles/bigquery.dataEditor"
  member  = "serviceAccount:service-${data.google_project.current.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
}

resource "google_project_iam_member" "pubsub_bq_metadata" {
  project = var.project_id
  role    = "roles/bigquery.metadataViewer"
  member  = "serviceAccount:service-${data.google_project.current.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
}

resource "google_pubsub_topic_iam_binding" "bq_sub_publisher" {
  topic = google_pubsub_topic.cdc_events.id
  role  = "roles/pubsub.publisher"
  members = [
    "serviceAccount:service-${data.google_project.current.number}@gcp-sa-pubsub.iam.gserviceaccount.com",
  ]
}

resource "google_pubsub_topic_iam_binding" "bq_sub_metadata" {
  topic = google_pubsub_topic.cdc_events.id
  role  = "roles/pubsub.subscriber"
  members = [
    "serviceAccount:service-${data.google_project.current.number}@gcp-sa-pubsub.iam.gserviceaccount.com",
  ]
}
