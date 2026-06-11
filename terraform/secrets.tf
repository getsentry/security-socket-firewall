resource "google_secret_manager_secret" "socket_api_token" {
  secret_id = var.socket_api_token_secret_id
  project   = var.project_id

  replication {
    auto {}
  }

  rotation {
    rotation_period    = "7776000s" # 90 days
    next_rotation_time = var.secret_next_rotation_time
  }

  topics {
    name = "projects/${var.project_id}/topics/secret-rotation"
  }

  depends_on = [google_project_service.required]
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
