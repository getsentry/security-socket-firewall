# ---------------------------------------------------------------------------
# GCP-managed TLS (Certificate Manager + GKE Gateway)
# ---------------------------------------------------------------------------
# When firewall_domain is set, Google issues and renews the certificate via
# Certificate Manager (DNS authorization). TLS terminates at the external GKE
# Gateway load balancer; pods serve plain HTTP behind it.
#
# After apply, publish the dns_authorization_record CNAME in your DNS zone so
# Google can validate domain ownership. Once the certificate is ACTIVE, point
# firewall_domain at the gateway IP from firewall_load_balancer_ip.
# ---------------------------------------------------------------------------

locals {
  use_gcp_managed_tls = local.firewall_domain != ""
}

resource "google_certificate_manager_dns_authorization" "firewall" {
  count = local.use_gcp_managed_tls ? 1 : 0

  name    = "${var.cluster_name}-dns-auth"
  domain  = local.firewall_domain
  project = var.project_id

  depends_on = [google_project_service.required]
}

resource "google_certificate_manager_certificate" "firewall" {
  count = local.use_gcp_managed_tls ? 1 : 0

  name    = "${var.cluster_name}-cert"
  project = var.project_id

  managed {
    domains = [local.firewall_domain]
    dns_authorizations = [
      google_certificate_manager_dns_authorization.firewall[0].id,
    ]
  }

  depends_on = [google_certificate_manager_dns_authorization.firewall]
}

resource "google_certificate_manager_certificate_map" "firewall" {
  count = local.use_gcp_managed_tls ? 1 : 0

  name    = "${var.cluster_name}-cert-map"
  project = var.project_id

  depends_on = [google_certificate_manager_certificate.firewall]
}

resource "google_certificate_manager_certificate_map_entry" "firewall" {
  count = local.use_gcp_managed_tls ? 1 : 0

  name         = "${var.cluster_name}-cert-entry"
  map          = google_certificate_manager_certificate_map.firewall[0].name
  hostname     = local.firewall_domain
  certificates = [google_certificate_manager_certificate.firewall[0].id]
  project      = var.project_id
}

resource "kubectl_manifest" "socket_firewall_gateway" {
  count = local.use_gcp_managed_tls ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "Gateway"
    metadata = {
      name      = "${var.cluster_name}-gateway"
      namespace = var.firewall_namespace
      annotations = {
        "networking.gke.io/certmap" = google_certificate_manager_certificate_map.firewall[0].name
      }
    }
    spec = {
      gatewayClassName = "gke-l7-global-external-managed"
      listeners = [
        {
          name     = "https"
          protocol = "HTTPS"
          port     = 443
          hostname = local.firewall_domain
          allowedRoutes = {
            namespaces = {
              from = "Same"
            }
          }
          # No tls block: TLS is configured entirely by the
          # networking.gke.io/certmap annotation above. Per GKE docs, including a
          # tls section alongside the certmap annotation is rejected — either by
          # the Gateway API CEL rule (certificateRefs/options required for
          # Terminate) or by GKE (certificateRefs conflicts with the certmap).
        },
      ]
    }
  })

  depends_on = [
    google_container_node_pool.main,
    google_certificate_manager_certificate_map_entry.firewall,
    helm_release.socket_firewall,
  ]
}

# kubectl_manifest does not expose the live object status, so read the gateway's
# assigned address back via the kubernetes provider for the output below.
data "kubernetes_resource" "firewall_gateway" {
  count = local.use_gcp_managed_tls ? 1 : 0

  api_version = "gateway.networking.k8s.io/v1"
  kind        = "Gateway"

  metadata {
    name      = "${var.cluster_name}-gateway"
    namespace = var.firewall_namespace
  }

  depends_on = [kubectl_manifest.socket_firewall_gateway]
}

resource "google_compute_ssl_policy" "firewall" {
  count = local.use_gcp_managed_tls ? 1 : 0

  name            = "${var.cluster_name}-ssl-policy"
  project         = var.project_id
  profile         = "MODERN"
  min_tls_version = "TLS_1_2"
}

resource "kubectl_manifest" "socket_firewall_gateway_policy" {
  count = local.use_gcp_managed_tls ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "networking.gke.io/v1"
    kind       = "GCPGatewayPolicy"
    metadata = {
      name      = "${var.cluster_name}-gateway-policy"
      namespace = var.firewall_namespace
    }
    spec = {
      default = {
        sslPolicy = google_compute_ssl_policy.firewall[0].name
      }
      targetRef = {
        group = "gateway.networking.k8s.io"
        kind  = "Gateway"
        name  = "${var.cluster_name}-gateway"
      }
    }
  })

  depends_on = [kubectl_manifest.socket_firewall_gateway]
}

resource "kubectl_manifest" "socket_firewall_http_route" {
  count = local.use_gcp_managed_tls ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "${var.cluster_name}-route"
      namespace = var.firewall_namespace
    }
    spec = {
      parentRefs = [
        {
          name = "${var.cluster_name}-gateway"
        },
      ]
      hostnames = [local.firewall_domain]
      rules = [
        {
          matches = [
            {
              path = {
                type  = "PathPrefix"
                value = "/"
              }
            },
          ]
          backendRefs = [
            {
              name = helm_release.socket_firewall.name
              port = 80
            },
          ]
        },
      ]
    }
  })

  depends_on = [kubectl_manifest.socket_firewall_gateway]
}

# Without this, the GKE Gateway health-checks the backend on "/" (its default),
# which the firewall does not answer with 200 on the HTTP port — so every
# endpoint is marked UNHEALTHY and the load balancer returns "no healthy
# upstream" even though the pods are Ready. Point the LB health check at
# /health (which the firewall serves 200 on the HTTP serving port, same as the
# pod readiness probe).
resource "kubectl_manifest" "socket_firewall_health_check" {
  count = local.use_gcp_managed_tls ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "networking.gke.io/v1"
    kind       = "HealthCheckPolicy"
    metadata = {
      name      = "${var.cluster_name}-healthcheck"
      namespace = var.firewall_namespace
    }
    spec = {
      default = {
        config = {
          type = "HTTP"
          httpHealthCheck = {
            portSpecification = "USE_SERVING_PORT"
            requestPath       = "/health"
          }
        }
      }
      targetRef = {
        group = ""
        kind  = "Service"
        name  = helm_release.socket_firewall.name
      }
    }
  })

  depends_on = [helm_release.socket_firewall]
}
