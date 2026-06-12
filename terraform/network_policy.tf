# ---------------------------------------------------------------------------
# Kubernetes NetworkPolicies
# ---------------------------------------------------------------------------
# Enforcement is provided by Calico (enabled on the cluster in gke.tf).
# Baseline: deny all ingress in the firewall namespace, then explicitly allow
# traffic to the firewall pods (load balancer + health checks). Egress is left
# to the VPC egress firewall (network.tf) to avoid breaking DNS / Socket.dev /
# registry traffic.
#
# Gated by var.enable_network_policies so it can be disabled quickly if the
# chart's pod labels differ from the assumed app.kubernetes.io/instance value.
# ---------------------------------------------------------------------------

resource "kubernetes_network_policy" "default_deny_ingress" {
  count = var.enable_network_policies ? 1 : 0

  metadata {
    name      = "default-deny-ingress"
    namespace = kubernetes_namespace.socket_firewall.metadata[0].name
  }

  spec {
    pod_selector {}
    policy_types = ["Ingress"]
  }

  depends_on = [helm_release.socket_firewall]
}

resource "kubernetes_network_policy" "allow_firewall_ingress" {
  count = var.enable_network_policies ? 1 : 0

  metadata {
    name      = "allow-firewall-ingress"
    namespace = kubernetes_namespace.socket_firewall.metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = {
        "app.kubernetes.io/instance" = helm_release.socket_firewall.name
      }
    }
    policy_types = ["Ingress"]

    # Empty rule = allow ingress to the firewall pods from any source
    # (internal gateway/LB proxy range and GKE health checkers).
    ingress {}
  }

  depends_on = [helm_release.socket_firewall]
}
