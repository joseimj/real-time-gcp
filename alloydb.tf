# ============================================================
# AlloyDB: hot tier para lookups < 10ms
# ============================================================

data "google_secret_manager_secret_version" "alloydb_password" {
  secret = var.alloydb_password_secret_id
}

resource "google_alloydb_cluster" "hot_tier" {
  cluster_id = "${local.prefix}-cluster"
  location   = var.region

  network_config {
    network = google_compute_network.vpc.id
  }

  # Password inicial del usuario postgres
  initial_user {
    user     = "postgres"
    password = data.google_secret_manager_secret_version.alloydb_password.secret_data
  }

  # Backups automáticos para DR
  automated_backup_policy {
    enabled       = true
    backup_window = "1800s"
    location      = var.region

    weekly_schedule {
      days_of_week = ["MONDAY", "TUESDAY", "WEDNESDAY", "THURSDAY", "FRIDAY", "SATURDAY", "SUNDAY"]
      start_times {
        hours = 2
      }
    }

    quantity_based_retention {
      count = 14  # 14 días
    }
  }

  # Continuous backup para PITR
  continuous_backup_config {
    enabled              = true
    recovery_window_days = 7
  }

  depends_on = [google_service_networking_connection.alloydb_peering]
}

# ============================================================
# Primary instance: maneja todas las escrituras (Dataflow upserts)
# ============================================================
resource "google_alloydb_instance" "primary" {
  cluster       = google_alloydb_cluster.hot_tier.name
  instance_id   = "${local.prefix}-primary"
  instance_type = "PRIMARY"

  machine_config {
    cpu_count = var.alloydb_cpu_count
  }

  # CRÍTICO para latencia baja: tuning de PostgreSQL
  database_flags = {
    # Cache: 25% de RAM para shared_buffers, AlloyDB lo maneja automáticamente
    # pero podemos forzar valores específicos:

    # Conexiones: AlloyDB default 1000, sube si necesitas más
    "max_connections" = "2000"

    # Workers paralelos para queries grandes (analytics queries que llegan al hot tier)
    "max_parallel_workers"             = tostring(var.alloydb_cpu_count * 2)
    "max_parallel_workers_per_gather"  = tostring(var.alloydb_cpu_count)
    "max_worker_processes"             = tostring(var.alloydb_cpu_count * 4)

    # SSD: planner es agresivo con índices
    "random_page_cost" = "1.1"

    # Concurrency I/O alta para SSD
    "effective_io_concurrency" = "200"

    # Memoria por operación
    "work_mem"             = "65536"   # 64MB
    "maintenance_work_mem" = "2097152" # 2GB

    # Logging: identifica queries lentas
    "log_min_duration_statement" = "100"  # Log queries > 100ms

    # Stats para query planner
    "default_statistics_target" = "500"

    # Columnar engine
    "google_columnar_engine.enabled"        = "on"
    "google_columnar_engine.memory_size_in_mb" = "4096"
  }

  # Métricas de query insights (gratis, muy útil para debugging)
  query_insights_config {
    query_string_length     = 1024
    record_application_tags = true
    record_client_address   = true
  }
}

# ============================================================
# Read pool: absorbe las lecturas de la aplicación
# CRÍTICO: las apps deben leer de aquí, no del primary
# ============================================================
resource "google_alloydb_instance" "read_pool" {
  cluster       = google_alloydb_cluster.hot_tier.name
  instance_id   = "${local.prefix}-read-pool"
  instance_type = "READ_POOL"

  read_pool_config {
    node_count = var.alloydb_read_pool_node_count
  }

  machine_config {
    cpu_count = var.alloydb_cpu_count
  }

  database_flags = {
    "max_connections"          = "2000"
    "random_page_cost"         = "1.1"
    "effective_io_concurrency" = "200"
    "work_mem"                 = "65536"
  }
}

# ============================================================
# Secret para connection string
# ============================================================
resource "google_secret_manager_secret" "alloydb_connection" {
  secret_id = "${local.prefix}-alloydb-conn-string"

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "alloydb_connection_value" {
  secret = google_secret_manager_secret.alloydb_connection.id

  # Connection string para que la app lea del read pool
  secret_data = "postgresql://app_reader@${google_alloydb_instance.read_pool.ip_address}:5432/postgres?sslmode=require"
}

# Connection string para Dataflow (escribe al primary)
resource "google_secret_manager_secret" "alloydb_writer_connection" {
  secret_id = "${local.prefix}-alloydb-writer-conn"

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "alloydb_writer_connection_value" {
  secret = google_secret_manager_secret.alloydb_writer_connection.id

  secret_data = "postgresql://dataflow_writer@${google_alloydb_instance.primary.ip_address}:5432/postgres?sslmode=require"
}
