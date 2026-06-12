# ---------------------------------------------------------------------------
# Customer-Managed Encryption Keys (CMEK)
# ---------------------------------------------------------------------------
# One key ring with dedicated keys for:
#   - GKE application-layer secrets encryption (etcd)
#   - GKE node boot disks
#   - The Secret Manager Socket API token secret
#
# Each key is granted to the relevant Google service agent so the service can
# encrypt/decrypt on the project's behalf. Keys auto-rotate every 90 days.
# ---------------------------------------------------------------------------

data "google_project" "this" {
  project_id = var.project_id
}

# Secret Manager service agent must exist before we can grant it KMS access.
resource "google_project_service_identity" "secretmanager" {
  provider = google-beta
  project  = var.project_id
  service  = "secretmanager.googleapis.com"

  depends_on = [google_project_service.required]
}

locals {
  gke_service_agent     = "serviceAccount:service-${data.google_project.this.number}@container-engine-robot.iam.gserviceaccount.com"
  compute_service_agent = "serviceAccount:service-${data.google_project.this.number}@compute-system.iam.gserviceaccount.com"
}

resource "google_kms_key_ring" "main" {
  name     = "${var.cluster_name}-keyring"
  location = var.region
  project  = var.project_id

  depends_on = [google_project_service.required]
}

# Key for GKE application-layer secrets encryption (etcd).
resource "google_kms_crypto_key" "gke_etcd" {
  name            = "${var.cluster_name}-gke-etcd"
  key_ring        = google_kms_key_ring.main.id
  purpose         = "ENCRYPT_DECRYPT"
  rotation_period = "7776000s" # 90 days

  lifecycle {
    prevent_destroy = true
  }
}

# Key for GKE node boot disks.
resource "google_kms_crypto_key" "node_disk" {
  name            = "${var.cluster_name}-node-disk"
  key_ring        = google_kms_key_ring.main.id
  purpose         = "ENCRYPT_DECRYPT"
  rotation_period = "7776000s"

  lifecycle {
    prevent_destroy = true
  }
}

# Key for the Secret Manager Socket API token secret.
resource "google_kms_crypto_key" "secret" {
  name            = "${var.cluster_name}-secret"
  key_ring        = google_kms_key_ring.main.id
  purpose         = "ENCRYPT_DECRYPT"
  rotation_period = "7776000s"

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_kms_crypto_key_iam_member" "gke_etcd" {
  crypto_key_id = google_kms_crypto_key.gke_etcd.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = local.gke_service_agent
}

resource "google_kms_crypto_key_iam_member" "node_disk" {
  crypto_key_id = google_kms_crypto_key.node_disk.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = local.compute_service_agent
}

resource "google_kms_crypto_key_iam_member" "secret" {
  crypto_key_id = google_kms_crypto_key.secret.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${google_project_service_identity.secretmanager.email}"
}
