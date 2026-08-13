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
  profile         = "RESTRICTED"
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
        # Defaults (unhealthyThreshold 2, healthyThreshold 2, 5s interval) eject
        # a backend after ~10s of slow /health responses and then need two
        # successes to bring it back. With only a couple of replicas, ejecting
        # one doubles load on the rest and can cascade — which is what
        # failed_to_pick_backend in the LB logs looks like. Tolerate one more
        # consecutive failure, and return the backend on the first success.
        checkIntervalSec   = 5
        timeoutSec         = 5
        unhealthyThreshold = 3
        healthyThreshold   = 1
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

# Backend-service behaviour for the Gateway-managed ALB. Without this the
# backend runs on GCP defaults: connection draining disabled (0s) and a 30s
# request timeout.
#
# drainingTimeoutSec: with draining off, a pod leaving the NEG (rollout, HPA
# scale-down, node autoscale/repair/upgrade) has its in-flight connections cut
# immediately, which reaches the client as a sporadic 503. The chart has no
# preStop hook, so LB-side draining is the drain available;
# terminationGracePeriodSeconds in helm.tf is set to outlive this window.
#
# timeoutSec: the firewall streams package artifacts, and large wheels
# (torch, nvidia-*) can exceed the 30s default on a slow upstream. 300s matches
# the firewall's own proxy.read_timeout default.
#
# logging: LB request logs carry jsonPayload.statusDetails, which names the
# reason for a 5xx (failed_to_pick_backend, backend_connection_closed_*, ...).
# Without it a 503 seen by a client is not attributable to a cause. Add
# sampleRate (1-1000000) to cut ingest volume once the cause is known.
resource "kubectl_manifest" "socket_firewall_backend_policy" {
  count = local.use_gcp_managed_tls ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "networking.gke.io/v1"
    kind       = "GCPBackendPolicy"
    metadata = {
      name      = "${var.cluster_name}-backend-policy"
      namespace = var.firewall_namespace
    }
    spec = {
      default = {
        timeoutSec = 300
        connectionDraining = {
          drainingTimeoutSec = 60
        }
        logging = {
          enabled = true
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
