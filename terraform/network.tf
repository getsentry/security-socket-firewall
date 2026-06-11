resource "google_compute_network" "main" {
  name                    = var.network_name
  auto_create_subnetworks = false

  depends_on = [google_project_service.required]
}

resource "google_compute_subnetwork" "main" {
  name          = var.subnet_name
  network       = google_compute_network.main.id
  region        = var.region
  ip_cidr_range = var.subnet_cidr

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = var.pods_cidr
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = var.services_cidr
  }

  private_ip_google_access = true

  log_config {
    aggregation_interval = "INTERVAL_5_SEC"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

# Deny all egress by default — lower priority than the allow rule below
resource "google_compute_firewall" "deny_egress_all" {
  name      = "${var.cluster_name}-deny-egress-all"
  network   = google_compute_network.main.id
  direction = "EGRESS"
  priority  = 65534

  deny {
    protocol = "all"
  }

  destination_ranges = ["0.0.0.0/0"]
  target_tags        = ["gke-${var.cluster_name}"]

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}

# Allow only TCP 80/443 egress to reach upstream registries and Socket.dev API
resource "google_compute_firewall" "allow_egress" {
  name      = "${var.cluster_name}-allow-egress"
  network   = google_compute_network.main.id
  direction = "EGRESS"
  priority  = 1000

  allow {
    protocol = "tcp"
    ports    = ["443", "80"]
  }

  destination_ranges = ["0.0.0.0/0"]
  target_tags        = ["gke-${var.cluster_name}"]

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}

# Cloud NAT so private nodes can reach the internet
resource "google_compute_router" "main" {
  name    = "${var.cluster_name}-router"
  region  = var.region
  network = google_compute_network.main.id
}

resource "google_compute_router_nat" "main" {
  name                               = "${var.cluster_name}-nat"
  router                             = google_compute_router.main.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"

  subnetwork {
    name                    = google_compute_subnetwork.main.id
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }
}
