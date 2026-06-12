resource "google_secret_manager_secret" "socket_api_token" {
  secret_id = var.socket_api_token_secret_id
  project   = var.project_id

  # Encrypt the secret with a customer-managed KMS key. CMEK requires
  # user-managed replication (auto replication does not support CMEK), so the
  # secret is pinned to a single region matching the KMS key.
  #
  # WARNING: replication policy is immutable. Switching an existing
  # auto-replicated secret to user-managed replication forces REPLACEMENT of
  # the secret (all existing versions are lost). After applying, re-add the
  # token value:
  #   gcloud secrets versions add <secret_id> --data-file=- <<< "sktsec_..."
  replication {
    user_managed {
      replicas {
        location = var.region
        customer_managed_encryption {
          kms_key_name = google_kms_crypto_key.secret.id
        }
      }
    }
  }

  depends_on = [
    google_project_service.required,
    google_kms_crypto_key_iam_member.secret,
  ]
}

# Reads the latest active version. The secret value must be added out-of-band
# before the first `terraform apply`:
#   gcloud secrets versions add <secret_id> --data-file=- <<< "sktsec_..."
# this will store the secret value in the tf state and anyone with state bucket access can read it
# but since this token doesn't really have any access other than check if package is malicious or not
# so gonna leave it as is for now
data "google_secret_manager_secret_version" "socket_api_token" {
  secret  = google_secret_manager_secret.socket_api_token.id
  version = "latest"

  depends_on = [google_secret_manager_secret.socket_api_token]
}
