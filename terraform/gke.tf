resource "google_container_cluster" "main" {
  name                = var.cluster_name
  location            = var.zone
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

  # The control plane is fully private (enable_private_endpoint = true), so
  # authorized networks must be internal/RFC1918 ranges — a public range like
  # the IAP forwarding block (35.235.240.0/20) is rejected here. IAP tunnels to
  # a VM, not to the control plane, so the only path in is:
  #   you -> IAP tunnel -> bastion/proxy VM in this subnet -> control plane.
  # The connection therefore originates from the bastion's internal IP, so we
  # authorize the internal subnet range.
  master_authorized_networks_config {
    cidr_blocks {
      cidr_block   = var.subnet_cidr
      display_name = "internal-subnet-bastion"
    }
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  # Encrypt Kubernetes Secrets in etcd with a customer-managed KMS key.
  database_encryption {
    state    = "ENCRYPTED"
    key_name = google_kms_crypto_key.gke_etcd.id
  }

  # Enforce Kubernetes NetworkPolicy with Calico. (Dataplane V2 is the
  # preferred long-term option but cannot be enabled in place on an existing
  # cluster — it requires cluster recreation.)
  network_policy {
    enabled  = true
    provider = "CALICO"
  }

  # Honor the project's Binary Authorization policy for image admission.
  binary_authorization {
    evaluation_mode = "PROJECT_SINGLETON_POLICY_ENFORCE"
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
    network_policy_config {
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
    ignore_changes = [min_master_version, database_encryption]
  }

  depends_on = [google_kms_crypto_key_iam_member.gke_etcd]
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

    # Encrypt node boot disks with a customer-managed KMS key.
    boot_disk_kms_key = google_kms_crypto_key.node_disk.id

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
    google_kms_crypto_key_iam_member.node_disk,
  ]
}
