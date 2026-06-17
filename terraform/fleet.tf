# ---------------------------------------------------------------------------
# Fleet membership + Connect Gateway
# ---------------------------------------------------------------------------
# Registering the cluster to the project fleet provisions the GKE-managed
# Connect agent, which opens an *outbound* channel to Google. Connect Gateway
# (connectgateway.googleapis.com) proxies kubectl/Terraform traffic down that
# channel, so the private control plane is reachable over IAM from local
# machines and GitHub-hosted CI runners — with no public endpoint, bastion, or
# IAP tunnel, and no inbound path to the private endpoint (172.16.0.x).
#
# The connect agent egresses to Google on TCP 443, which the existing
# allow_egress firewall rule already permits — no firewall change is required.
#
# SECURITY / BOOTSTRAP NOTE
# Creating this membership requires gkehub.memberships.create (roles/gkehub.editor
# or admin). That is intentionally a *bootstrap* permission, granted to the
# apply SA only for the first apply (see iam.tf). Steady-state plan/apply runs
# only refresh this resource, which needs gkehub.memberships.get — covered by
# roles/gkehub.viewer (apply SA) and the plan SA's read-only role — so neither
# WIF-triggered identity is left holding fleet write access.
# ---------------------------------------------------------------------------

resource "google_gke_hub_membership" "main" {
  provider      = google-beta
  membership_id = var.cluster_name
  location      = "global"

  endpoint {
    gke_cluster {
      resource_link = "//container.googleapis.com/${google_container_cluster.main.id}"
    }
  }

  depends_on = [
    google_project_service.required,
    google_container_node_pool.main,
  ]

  lifecycle {
    # Accidental deletion drops the only CI/local path to the control plane.
    prevent_destroy = true
  }
}
