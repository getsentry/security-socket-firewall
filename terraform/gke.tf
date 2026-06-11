resource "google_container_cluster" "main" {
  name               = var.cluster_name
  location           = var.zone
  deletion_protection = true

  # Remove the default node pool immediately and manage it separately
  remove_default_node_pool = true
  initial_node_count       = 1

  network    = google_compute_network.main.id
  subnetwork = google_compute_subnetwork.main.id

  min_master_version = var.kubernetes_version != "" ? var.kubernetes_version : null

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = true
    master_ipv4_cidr_block  = "172.16.0.0/28"
  }

  # IAP TCP forwarding range — the only path to the control plane
  master_authorized_networks_config {
    cidr_blocks {
      cidr_block   = "35.235.240.0/20"
      display_name = "iap-tcp-forwarding"
    }
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  release_channel {
    channel = "REGULAR"
  }

  addons_config {
    http_load_balancing {
      disabled = false
    }
    horizontal_pod_autoscaling {
      disabled = false
    }
  }

  gateway_api_config {
    channel = "CHANNEL_STANDARD"
  }

  maintenance_policy {
    recurring_window {
      start_time = "2024-01-01T03:00:00Z"
      end_time   = "2024-01-01T07:00:00Z"
      recurrence = "FREQ=WEEKLY;BYDAY=SA,SU"
    }
  }

  lifecycle {
    ignore_changes = [min_master_version]
  }
}

resource "google_container_node_pool" "main" {
  name       = "${var.cluster_name}-nodes"
  cluster    = google_container_cluster.main.id
  location   = var.zone
  node_count = var.node_count

  autoscaling {
    min_node_count = var.node_min_count
    max_node_count = var.node_max_count
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  node_config {
    machine_type    = var.node_machine_type
    disk_size_gb    = 50
    disk_type       = "pd-ssd"
    service_account = google_service_account.gke_node.email

    # Narrow scopes to match the node SA's granted roles.
    # cloud-platform is intentionally avoided — scopes + IAM roles together
    # form the effective permission boundary.
    oauth_scopes = [
      "https://www.googleapis.com/auth/logging.write",
      "https://www.googleapis.com/auth/monitoring",
      "https://www.googleapis.com/auth/monitoring.write",
    ]

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    metadata = {
      disable-legacy-endpoints = "true"
    }

    tags = ["gke-${var.cluster_name}"]
  }

  upgrade_settings {
    max_surge       = 1
    max_unavailable = 0
  }

  depends_on = [
    google_project_iam_member.gke_node_log_writer,
    google_project_iam_member.gke_node_metric_writer,
    google_project_iam_member.gke_node_monitoring_viewer,
    google_project_iam_member.gke_node_stackdriver_writer,
    google_service_account_iam_member.tf_sa_node_actas,
  ]
}
