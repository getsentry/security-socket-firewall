# ---------------------------------------------------------------------------
# Supplemental Kubernetes RBAC for the plan SA
# ---------------------------------------------------------------------------
# roles/container.viewer maps to the predefined "view" ClusterRole, which
# deliberately omits secrets. Terraform plan still refreshes
# kubernetes_secret.socket_api_token (helm.tf), which calls the Kubernetes API
# secrets.get endpoint. Grant read-only secret access in this namespace only.
# ---------------------------------------------------------------------------

resource "kubernetes_role" "tf_plan_secret_reader" {
  metadata {
    name      = "terraform-plan-secret-reader"
    namespace = kubernetes_namespace.socket_firewall.metadata[0].name
  }

  rule {
    api_groups = [""]
    resources  = ["secrets"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_role_binding" "tf_plan_secret_reader" {
  metadata {
    name      = "terraform-plan-secret-reader"
    namespace = kubernetes_namespace.socket_firewall.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.tf_plan_secret_reader.metadata[0].name
  }

  subject {
    kind      = "User"
    name      = var.terraformer_plan
    api_group = "rbac.authorization.k8s.io"
  }
}
