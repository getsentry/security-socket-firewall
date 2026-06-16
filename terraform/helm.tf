locals {
  firewall_domain = trim(var.firewall_domain, ".")

  tls_secret_name = var.tls_existing_secret != "" ? var.tls_existing_secret : ""

  helm_values = {
    replicaCount = var.replica_count

    autoscaling = {
      enabled = var.enable_autoscaling
    }

    # The socket-registry-firewall:1.1.159 image runs as UID 1001, but the
    # chart's cert-generator init container defaults to runAsUser 1000 and writes
    # /etc/nginx/ssl/privkey.pem mode 0600 (owner-only). The UID mismatch makes
    # nginx (1001) unable to read the key -> "Permission denied" -> CrashLoop.
    # Align the cert generator to the image's runtime UID so the main container
    # owns and can read the generated key. fsGroup is set as a belt-and-suspenders
    # so the shared EmptyDir volumes are group-accessible too.
    podSecurityContext = {
      fsGroup = 1001
    }

    initContainers = {
      certGenerator = {
        securityContext = {
          allowPrivilegeEscalation = false
          readOnlyRootFilesystem   = true
          runAsNonRoot             = true
          runAsUser                = 1001
          capabilities = {
            drop = ["ALL"]
          }
          seccompProfile = {
            type = "RuntimeDefault"
          }
        }
      }
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

    service = merge(
      {
        type = local.use_gcp_managed_tls ? "ClusterIP" : "LoadBalancer"
      },
      local.use_gcp_managed_tls ? {
        httpsTargetPort = "http"
      } : {},
      (!local.use_gcp_managed_tls && var.internal_load_balancer) ? {
        annotations = {
          "networking.gke.io/load-balancer-type" = "Internal"
        }
      } : {}
    )

    # The Socket Firewall container always serves HTTPS on its internal port and
    # its health check is `curl -fk https://localhost:8443/health`, so it needs a
    # cert present or the listener (and the probe) never come up. With GCP-managed
    # TLS the Gateway still terminates the *public* trusted certificate; the pod
    # keeps a self-signed cert only for the internal Gateway->pod hop (ClusterIP,
    # not externally reachable).
    tls = local.use_gcp_managed_tls ? {
      generateSelfSigned = true
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

    # Spread replicas across nodes so a single node loss doesn't take down
    # the firewall. Soft (preferred) so scheduling still succeeds on one node.
    affinity = {
      podAntiAffinity = {
        preferredDuringSchedulingIgnoredDuringExecution = [
          {
            weight = 100
            podAffinityTerm = {
              topologyKey = "kubernetes.io/hostname"
              labelSelector = {
                matchLabels = {
                  "app.kubernetes.io/instance" = "socket-firewall"
                }
              }
            }
          },
        ]
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
  timeout    = 600

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

# Note: the socket-firewall Helm chart already creates its own
# PodDisruptionBudget (min available 1) for these pods, so no Terraform-managed
# PDB is needed. A second PDB on the same selector triggers
# "MultiplePodDisruptionBudgets" warnings and can interfere with rollouts.
