locals {
  firewall_domain = trim(var.firewall_domain, ".")

  tls_secret_name = var.tls_existing_secret != "" ? var.tls_existing_secret : ""

  helm_values = {
    replicaCount = var.replica_count

    autoscaling = {
      enabled = var.enable_autoscaling
    }

    socket = {
      existingSecret    = kubernetes_secret.socket_api_token.metadata[0].name
      existingSecretKey = "SOCKET_SECURITY_API_TOKEN"
      failOpen          = false
      failOpenUnscanned = false
    }

    pathRouting = local.firewall_domain != "" ? {
      enabled = true
      domain  = local.firewall_domain
      routes  = var.path_routing_routes
      } : {
      enabled = false
      domain  = ""
      routes  = []
    }

    service = local.use_gcp_managed_tls ? {
      type            = "ClusterIP"
      httpsTargetPort = "http"
      } : merge(
      {
        type = "LoadBalancer"
      },
      var.internal_load_balancer ? {
        annotations = {
          "networking.gke.io/load-balancer-type" = "Internal"
        }
      } : {}
    )

    # When GCP-managed TLS is active, TLS terminates at the Gateway and pods
    # serve plain HTTP — disable self-signed cert generation so port 443 is
    # not silently open on the pods with an unmanaged certificate.
    tls = local.use_gcp_managed_tls ? {
      generateSelfSigned = false
      } : local.tls_secret_name != "" ? {
      generateSelfSigned = false
      existingSecret     = local.tls_secret_name
      certManager        = var.tls_cert_manager_format
      includeCaCrt       = var.tls_include_ca_crt
      } : {
      generateSelfSigned = true
    }

    resources = {
      requests = {
        cpu    = "500m"
        memory = "512Mi"
      }
      limits = {
        cpu    = "1"
        memory = "768Mi"
      }
    }
  }
}

resource "kubernetes_namespace" "socket_firewall" {
  metadata {
    name = var.firewall_namespace
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  depends_on = [google_container_node_pool.main]
}

resource "kubernetes_secret" "socket_api_token" {
  metadata {
    name      = "socket-api-token"
    namespace = kubernetes_namespace.socket_firewall.metadata[0].name
  }

  data = {
    SOCKET_SECURITY_API_TOKEN = data.google_secret_manager_secret_version.socket_api_token.secret_data
  }

  type = "Opaque"
}

resource "helm_release" "socket_firewall" {
  name       = "socket-firewall"
  namespace  = kubernetes_namespace.socket_firewall.metadata[0].name
  repository = "https://socketdev-demo.github.io/socket-firewall-helm"
  chart      = "socket-firewall"
  version    = var.helm_chart_version
  wait       = true
  timeout    = 300

  values = [yamlencode(local.helm_values)]

  depends_on = [
    kubernetes_namespace.socket_firewall,
    kubernetes_secret.socket_api_token,
  ]
}

data "kubernetes_service" "socket_firewall" {
  metadata {
    name      = helm_release.socket_firewall.name
    namespace = kubernetes_namespace.socket_firewall.metadata[0].name
  }

  depends_on = [helm_release.socket_firewall]
}
