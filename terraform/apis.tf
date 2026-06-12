# ---------------------------------------------------------------------------
# Required GCP APIs
# ---------------------------------------------------------------------------
# Enable all APIs this stack depends on before creating resources.
# Bootstrap identity needs serviceusage.services.enable (or Owner/Editor)
# on the project to run the first apply.
# ---------------------------------------------------------------------------

locals {
  required_apis = toset([
    "cloudresourcemanager.googleapis.com", # project IAM bindings
    "compute.googleapis.com",              # VPC, NAT, firewall, GKE nodes, LoadBalancer
    "container.googleapis.com",            # GKE cluster and node pools
    "iam.googleapis.com",                  # service accounts and IAM bindings
    "logging.googleapis.com",              # node log writer
    "monitoring.googleapis.com",           # node metrics
    "secretmanager.googleapis.com",        # Socket API token secret
    "certificatemanager.googleapis.com",   # GCP-managed TLS certificates
    "servicenetworking.googleapis.com",    # private GKE control plane VPC peering
    "cloudkms.googleapis.com",             # CMEK keys for GKE, node disks, secret
    "binaryauthorization.googleapis.com",  # image admission policy enforcement
    "gkehub.googleapis.com",               # fleet membership for the cluster
    "connectgateway.googleapis.com",       # Connect Gateway proxy to the private control plane
  ])
}

resource "google_project_service" "required" {
  for_each = local.required_apis

  project = var.project_id
  service = each.value

  disable_on_destroy         = false
  disable_dependent_services = false
}
