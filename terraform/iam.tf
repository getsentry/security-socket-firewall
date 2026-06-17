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
#     --member="<SERVICE_ACCOUNT_EMAIL>" \
#     --role="roles/<ROLE>"
# ---------------------------------------------------------------------------

locals {
  tf_sa_member      = "serviceAccount:${var.terraformer}"
  tf_plan_sa_member = "serviceAccount:${var.terraformer_plan}"
}

# ---------------------------------------------------------------------------
# GKE management — replaces roles/container.admin (GCP control plane only)
#
# roles/container.admin also grants Kubernetes API permissions (pods.exec,
# pods.portForward, secrets.get via kubectl, etc.) that a Terraform SA never
# needs for cluster/node-pool lifecycle management. This custom role restricts
# to GCP control-plane operations only.
#
# Kubernetes API access for the Helm/kubectl/kubernetes providers is covered
# separately by roles/container.developer below.
# ---------------------------------------------------------------------------
resource "google_project_iam_custom_role" "tf_gke_manager" {
  role_id     = "socketFirewallTfGkeManager"
  title       = "Socket Firewall TF GKE Manager"
  description = "GCP-level GKE cluster and node pool management for Terraform. Excludes Kubernetes API permissions."
  project     = var.project_id
  permissions = [
    "container.clusters.create",
    "container.clusters.delete",
    "container.clusters.get",
    "container.clusters.list",
    "container.clusters.update", # also covers node pool create/update/delete via the GKE API
    "container.operations.get",
    "container.operations.list",
  ]
}

resource "google_project_iam_member" "tf_sa_gke_manager" {
  project = var.project_id
  role    = google_project_iam_custom_role.tf_gke_manager.id
  member  = local.tf_sa_member
}

# Kubernetes API access for the helm/kubernetes/kubectl Terraform providers.
# roles/container.developer maps to the "edit" RBAC ClusterRole in GKE's
# IAM-to-RBAC webhook, which covers namespaced workload resources (Deployments,
# Services, ConfigMaps, Secrets, NetworkPolicies) that Helm manages. It does NOT
# grant pod exec or port-forward (unlike container.admin).
resource "google_project_iam_member" "tf_sa_k8s_developer" {
  project = var.project_id
  role    = "roles/container.developer"
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

# ---------------------------------------------------------------------------
# KMS management — replaces roles/cloudkms.admin
#
# cloudkms.admin includes key ring and key version destruction, which a
# Terraform SA should not hold given that the KMS keys protect etcd secrets
# and node disks. This custom role covers only the lifecycle operations
# Terraform actually performs. Key/version destruction is intentionally omitted
# to complement the prevent_destroy lifecycle guards in kms.tf.
# ---------------------------------------------------------------------------
resource "google_project_iam_custom_role" "tf_kms_manager" {
  role_id     = "socketFirewallTfKmsManager"
  title       = "Socket Firewall TF KMS Manager"
  description = "KMS key ring and key management for Terraform. Excludes key ring deletion and key/version destruction."
  project     = var.project_id
  permissions = [
    "cloudkms.keyRings.create",
    "cloudkms.keyRings.get",
    "cloudkms.keyRings.list",
    "cloudkms.keyRings.getIamPolicy",
    "cloudkms.cryptoKeys.create",
    "cloudkms.cryptoKeys.get",
    "cloudkms.cryptoKeys.list",
    "cloudkms.cryptoKeys.update",
    "cloudkms.cryptoKeys.getIamPolicy",
    "cloudkms.cryptoKeys.setIamPolicy",
    "cloudkms.cryptoKeyVersions.get",
    "cloudkms.cryptoKeyVersions.list",
  ]
}

resource "google_project_iam_member" "tf_sa_kms_manager" {
  project = var.project_id
  role    = google_project_iam_custom_role.tf_kms_manager.id
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

# The plan SA must also read the token: the google_secret_manager_secret_version
# data source (secrets.tf) is evaluated during `terraform plan`, which calls
# AccessSecretVersion. Resource-scoped like the apply SA above, so the plan SA
# still cannot read any other secret in the project.
resource "google_secret_manager_secret_iam_member" "tf_plan_sa_secret_accessor" {
  secret_id = google_secret_manager_secret.socket_api_token.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = local.tf_plan_sa_member
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

# ---------------------------------------------------------------------------
# Fleet Connect Gateway access for the apply SA
# ---------------------------------------------------------------------------
# The apply SA reaches the private control plane through Connect Gateway (see
# main.tf) to create the namespace, secret, Helm release, and Gateway manifests.
# Scoped to the minimum the steady-state pipeline needs:
#
#   roles/gkehub.gatewayEditor — proxy kubectl/Terraform writes through the gateway.
#   roles/gkehub.viewer        — refresh the existing fleet membership during apply
#                                (gkehub.memberships.get/list).
#
# Deliberately NOT granted at runtime: roles/gkehub.editor (memberships.create/
# delete). Registering the membership is a one-time bootstrap step — grant the
# bootstrap identity gkehub.editor for the first apply, then revoke it so the
# internet-reachable CI identity cannot register/deregister fleet clusters:
#
#   gcloud projects add-iam-policy-binding sentry-socket \
#     --member="serviceAccount:${var.terraformer}" \
#     --role="roles/gkehub.editor"   # bootstrap only; revoke after first apply
#
# In-cluster authorization is covered by roles/container.developer above (GKE's
# IAM-to-RBAC webhook applies over the gateway), so no extra RBAC is required.
resource "google_project_iam_member" "tf_sa_gateway_editor" {
  project = var.project_id
  role    = "roles/gkehub.gatewayEditor"
  member  = local.tf_sa_member
}

resource "google_project_iam_member" "tf_sa_gkehub_viewer" {
  project = var.project_id
  role    = "roles/gkehub.viewer"
  member  = local.tf_sa_member
}

# ---------------------------------------------------------------------------
# Plan SA — read-only access for terraform plan CI runs
# ---------------------------------------------------------------------------
# The plan SA can read all resources managed by this stack to produce an
# accurate diff, but cannot create, update, or delete anything.
#
# NOTE: the plan SA also needs read access to the GCS state bucket. This
# cannot be managed here (it's the Terraform backend). Grant it manually:
#
#   gsutil iam ch \
#     serviceAccount:<PLAN_SA_EMAIL>:objectViewer \
#     gs://<STATE_BUCKET>
# ---------------------------------------------------------------------------
resource "google_project_iam_custom_role" "tf_plan_reader" {
  role_id     = "socketFirewallTfPlanReader"
  title       = "Socket Firewall TF Plan Reader"
  description = "Read-only access across all services managed by this Terraform stack. Used by the plan-only SA."
  project     = var.project_id
  permissions = [
    # GKE — container.nodePools.* and container.operations.* are not supported
    # in custom roles; cluster reads cover node pool state via the GKE API.
    "container.clusters.get",
    "container.clusters.list",
    # KMS
    "cloudkms.keyRings.get",
    "cloudkms.keyRings.list",
    "cloudkms.keyRings.getIamPolicy",
    "cloudkms.cryptoKeys.get",
    "cloudkms.cryptoKeys.list",
    "cloudkms.cryptoKeys.getIamPolicy",
    "cloudkms.cryptoKeyVersions.get",
    "cloudkms.cryptoKeyVersions.list",
    # Networking
    "compute.networks.get",
    "compute.networks.list",
    "compute.subnetworks.get",
    "compute.subnetworks.list",
    "compute.routers.get",
    "compute.routers.list",
    "compute.firewalls.get",
    "compute.firewalls.list",
    "compute.addresses.get",
    "compute.addresses.list",
    "compute.globalAddresses.get",
    "compute.globalAddresses.list",
    # SSL policy attached to the Gateway frontend (tls.tf)
    "compute.sslPolicies.get",
    "compute.sslPolicies.list",
    # Backing managed instance group of the GKE node pool (read on node-pool refresh)
    "compute.instanceGroupManagers.get",
    "compute.instanceGroupManagers.list",
    # IAM — service accounts and custom roles
    "iam.serviceAccounts.get",
    "iam.serviceAccounts.list",
    "iam.serviceAccounts.getIamPolicy",
    "iam.roles.get",
    "iam.roles.list",
    # Project IAM (needed to refresh google_project_iam_member drift)
    "resourcemanager.projects.get",
    "resourcemanager.projects.getIamPolicy",
    # Secret Manager (metadata only — token payload is granted resource-scoped
    # via google_secret_manager_secret_iam_member.tf_plan_sa_secret_accessor)
    "secretmanager.secrets.get",
    "secretmanager.secrets.list",
    "secretmanager.secrets.getIamPolicy",
    "secretmanager.versions.get",
    "secretmanager.versions.list",
    # APIs
    "serviceusage.services.get",
    "serviceusage.services.list",
    # Fleet / GKE Hub
    "gkehub.memberships.get",
    "gkehub.memberships.list",
  ]
}

resource "google_project_iam_member" "tf_plan_sa_reader" {
  project = var.project_id
  role    = google_project_iam_custom_role.tf_plan_reader.id
  member  = local.tf_plan_sa_member
}

# Kubernetes API read access for the helm/kubernetes/kubectl providers during plan.
# roles/container.viewer maps to the "view" RBAC ClusterRole in GKE.
resource "google_project_iam_member" "tf_plan_sa_k8s_viewer" {
  project = var.project_id
  role    = "roles/container.viewer"
  member  = local.tf_plan_sa_member
}

# Certificate Manager read — predefined viewer role used here because the
# individual certificatemanager.* permissions are not all supported in custom roles.
resource "google_project_iam_member" "tf_plan_sa_cert_manager_viewer" {
  project = var.project_id
  role    = "roles/certificatemanager.viewer"
  member  = local.tf_plan_sa_member
}

# Connect Gateway read access — allows the plan SA to reach the private
# control plane endpoint through the fleet gateway during terraform plan.
resource "google_project_iam_member" "tf_plan_sa_gateway_viewer" {
  project = var.project_id
  role    = "roles/gkehub.gatewayReader"
  member  = local.tf_plan_sa_member
}
