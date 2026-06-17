resource "google_container_cluster" "main" {
  name                = var.cluster_name
  location            = var.zone
  deletion_protection = true

  resource_labels = {
    app  = "socket-firewall"
    env  = "prod"
    team = "team-security-2"
  }

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

  # No master_authorized_networks_config: the control plane is private
  # (enable_private_endpoint = true) and reached only via fleet Connect Gateway
  # (see main.tf / fleet.tf), whose traffic does not originate from a subnet IP.
  # There is no bastion in this stack, so authorizing the subnet would be dead
  # config that widens the allowed source set for no benefit.
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
      # 02:00–06:00 UTC: after SF close, before Vienna open (both CET/CEST and PST/PDT).
      start_time = "2026-01-01T02:00:00Z"
      end_time   = "2026-01-01T06:00:00Z"
      recurrence = "FREQ=WEEKLY;BYDAY=SA,SU"
    }
  }

  lifecycle {
    ignore_changes = [min_master_version, database_encryption]
  }

  depends_on = [google_kms_crypto_key_iam_member.gke_etcd]
}

resource "google_container_node_pool" "main" {
  name     = "${var.cluster_name}-nodes"
  cluster  = google_container_cluster.main.id
  location = var.zone

  # node_count is intentionally unset — the autoscaling block owns the node
  # count. Setting it would make Terraform fight the autoscaler on apply.
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
