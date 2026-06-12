# ---------------------------------------------------------------------------
# GKE Node Service Account (least privilege)
# ---------------------------------------------------------------------------
# A dedicated SA for GKE nodes, replacing the over-privileged default
# Compute Engine SA. Only the minimum roles needed for node operation
# and GKE metadata are granted.
# ---------------------------------------------------------------------------

resource "google_service_account" "gke_node" {
  account_id   = "${var.cluster_name}-node"
  display_name = "Socket Firewall GKE Node SA"
  project      = var.project_id

  depends_on = [google_project_service.required]
}

# Write logs to Cloud Logging
resource "google_project_iam_member" "gke_node_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = google_service_account.gke_node.member
}

# Push metrics to Cloud Monitoring
resource "google_project_iam_member" "gke_node_metric_writer" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = google_service_account.gke_node.member
}

# Read monitoring metadata (required by the GKE node agent)
resource "google_project_iam_member" "gke_node_monitoring_viewer" {
  project = var.project_id
  role    = "roles/monitoring.viewer"
  member  = google_service_account.gke_node.member
}

# Allow nodes to report resource usage (GKE resource metrics)
resource "google_project_iam_member" "gke_node_stackdriver_writer" {
  project = var.project_id
  role    = "roles/stackdriver.resourceMetadata.writer"
  member  = google_service_account.gke_node.member
}

# ---------------------------------------------------------------------------
# Terraform Deployment Service Account roles
# ---------------------------------------------------------------------------
# These bindings grant the Terraform SA the minimum permissions to manage
# this stack. They must be applied by a project owner/admin during bootstrap
# (before the SA can run `terraform apply` itself).
#
# NOTE: the custom roles below require the bootstrap identity to hold
# roles/iam.roleAdmin (iam.roles.create) so the roles can be created and
# bound on the first apply.
#
# Bootstrap command:
#   gcloud projects add-iam-policy-binding <PROJECT_ID> \
#     --member="serviceAccount:socket-firewall-tf-apply@sac-prod-sa.iam.gserviceaccount.com" \
#     --role="roles/<ROLE>"
# ---------------------------------------------------------------------------

locals {
  tf_sa_member = "serviceAccount:${var.terraformer}"
}

# Create/manage GKE clusters and node pools
resource "google_project_iam_member" "tf_sa_container_admin" {
  project = var.project_id
  role    = "roles/container.admin"
  member  = local.tf_sa_member
}

# Create/manage VPC, subnets, firewall rules, Cloud NAT, and routers
resource "google_project_iam_member" "tf_sa_network_admin" {
  project = var.project_id
  role    = "roles/compute.networkAdmin"
  member  = local.tf_sa_member
}

# Least-privilege replacement for roles/iam.serviceAccountAdmin.
# Limited to the verbs needed to manage the GKE node service account. (Service
# account *creation* and setIamPolicy are inherently project-scoped in GCP, so
# this cannot be narrowed to a single resource — but it drops every unused
# permission the predefined role would otherwise grant.)
resource "google_project_iam_custom_role" "tf_sa_manager" {
  role_id     = "socketFirewallTfServiceAccountManager"
  title       = "Socket Firewall TF Service Account Manager"
  description = "Minimal permissions for the socket-firewall Terraform SA to manage the GKE node service account."
  project     = var.project_id
  permissions = [
    "iam.serviceAccounts.create",
    "iam.serviceAccounts.get",
    "iam.serviceAccounts.list",
    "iam.serviceAccounts.update",
    "iam.serviceAccounts.delete",
    "iam.serviceAccounts.getIamPolicy",
    "iam.serviceAccounts.setIamPolicy",
  ]
}

resource "google_project_iam_member" "tf_sa_sa_admin" {
  project = var.project_id
  role    = google_project_iam_custom_role.tf_sa_manager.id
  member  = local.tf_sa_member
}

# Least-privilege replacement for roles/secretmanager.secretAdmin.
# Crucially this OMITS secretmanager.versions.access, so the deploy SA can no
# longer read the payload of every secret in the project. Reading this stack's
# own secret is granted resource-scoped via tf_sa_secret_accessor below.
resource "google_project_iam_custom_role" "tf_secret_manager" {
  role_id     = "socketFirewallTfSecretManager"
  title       = "Socket Firewall TF Secret Manager"
  description = "Minimal Secret Manager permissions for the socket-firewall Terraform SA (no project-wide payload access)."
  project     = var.project_id
  permissions = [
    "secretmanager.secrets.create",
    "secretmanager.secrets.get",
    "secretmanager.secrets.list",
    "secretmanager.secrets.update",
    "secretmanager.secrets.delete",
    "secretmanager.secrets.getIamPolicy",
    "secretmanager.secrets.setIamPolicy",
    "secretmanager.versions.add",
    "secretmanager.versions.get",
    "secretmanager.versions.list",
    "secretmanager.versions.enable",
    "secretmanager.versions.disable",
    "secretmanager.versions.destroy",
  ]
}

# KMS: allow the deploy SA to manage the CMEK key ring, keys, and their
# IAM bindings.
resource "google_project_iam_member" "tf_sa_kms_admin" {
  project = var.project_id
  role    = "roles/cloudkms.admin"
  member  = local.tf_sa_member
}

# Allow TF SA to read the socket API token secret value (to populate the k8s secret)
# Scoped to the specific secret — not project-wide secretmanager access
resource "google_secret_manager_secret_iam_member" "tf_sa_secret_accessor" {
  secret_id = google_secret_manager_secret.socket_api_token.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = local.tf_sa_member
  project   = var.project_id
}

# Allow TF SA to create and manage secret resources (does NOT include reading secret values —
# that is covered by the resource-scoped secretAccessor binding above)
resource "google_project_iam_member" "tf_sa_secret_admin" {
  project = var.project_id
  role    = google_project_iam_custom_role.tf_secret_manager.id
  member  = local.tf_sa_member
}

# Allow TF SA to attach the node SA to GKE node pool VMs
resource "google_service_account_iam_member" "tf_sa_node_actas" {
  service_account_id = google_service_account.gke_node.name
  role               = "roles/iam.serviceAccountUser"
  member             = local.tf_sa_member
}

# Create/manage Certificate Manager certs, DNS authorizations, and cert maps
resource "google_project_iam_member" "tf_sa_certificate_manager_editor" {
  project = var.project_id
  role    = "roles/certificatemanager.editor"
  member  = local.tf_sa_member
}
