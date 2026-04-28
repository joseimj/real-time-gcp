# ============================================================
# Networking
# Crítico para latencia: todo en la misma VPC y región.
# AlloyDB con private IP, Dataflow workers con private IP,
# Oracle alcanzable vía VPN/Interconnect.
# ============================================================

resource "google_compute_network" "vpc" {
  name                    = "${local.prefix}-vpc"
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"

  depends_on = [google_project_service.required_apis]
}

resource "google_compute_subnetwork" "primary" {
  name                     = "${local.prefix}-subnet-primary"
  network                  = google_compute_network.vpc.id
  region                   = var.region
  ip_cidr_range            = "10.10.0.0/20"
  private_ip_google_access = true

  # Logs para debugging — en prod considera el costo
  log_config {
    aggregation_interval = "INTERVAL_10_MIN"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

# Subnet específica para Dataflow workers
resource "google_compute_subnetwork" "dataflow" {
  name                     = "${local.prefix}-subnet-dataflow"
  network                  = google_compute_network.vpc.id
  region                   = var.region
  ip_cidr_range            = "10.10.16.0/20"
  private_ip_google_access = true
}

# ============================================================
# Service Networking peering: requerido para AlloyDB con private IP
# ============================================================
resource "google_compute_global_address" "private_ip_range" {
  name          = "${local.prefix}-alloydb-range"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = google_compute_network.vpc.id
}

resource "google_service_networking_connection" "alloydb_peering" {
  network                 = google_compute_network.vpc.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_ip_range.name]

  depends_on = [google_project_service.required_apis]
}

# ============================================================
# Cloud NAT: para que Dataflow workers sin IP pública alcancen
# servicios externos (PyPI, etc.) durante setup
# ============================================================
resource "google_compute_router" "nat_router" {
  name    = "${local.prefix}-nat-router"
  network = google_compute_network.vpc.id
  region  = var.region
}

resource "google_compute_router_nat" "nat" {
  name                               = "${local.prefix}-nat"
  router                             = google_compute_router.nat_router.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# ============================================================
# Firewall rules
# ============================================================
# Permitir tráfico interno dentro de la VPC
resource "google_compute_firewall" "allow_internal" {
  name      = "${local.prefix}-allow-internal"
  network   = google_compute_network.vpc.name
  direction = "INGRESS"

  source_ranges = [
    "10.10.0.0/16",  # VPC range
  ]

  allow {
    protocol = "tcp"
  }
  allow {
    protocol = "udp"
  }
  allow {
    protocol = "icmp"
  }
}

# Datastream → Oracle via reverse SSH proxy
# Asume que tienes un bastion en GCP que tunea hacia Oracle
resource "google_compute_firewall" "allow_datastream_to_proxy" {
  name      = "${local.prefix}-allow-datastream-proxy"
  network   = google_compute_network.vpc.name
  direction = "INGRESS"

  # Datastream usa IPs específicas por región. Para us-central1:
  # Consulta https://cloud.google.com/datastream/docs/ip-allowlists-and-regions
  source_ranges = ["35.235.240.0/20"]

  target_tags = ["datastream-proxy"]

  allow {
    protocol = "tcp"
    ports    = ["1521"]  # Oracle listener
  }
}

# ============================================================
# Datastream Private Connectivity
# Requerido para que Datastream alcance Oracle privadamente
# ============================================================
resource "google_datastream_private_connection" "oracle_psc" {
  display_name          = "${local.prefix}-oracle-private-conn"
  location              = var.region
  private_connection_id = "${local.prefix}-oracle-pc"

  vpc_peering_config {
    vpc    = google_compute_network.vpc.id
    subnet = "10.10.32.0/29"  # /29 dedicado para Datastream peering
  }

  depends_on = [google_project_service.required_apis]
}
