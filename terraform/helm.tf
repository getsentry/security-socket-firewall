locals {
  helm_values = {
    replicaCount = var.replica_count

    # Pin the image tag explicitly instead of inheriting the chart default (latest).
    # Version bumps are proposed by the check-firewall-versions workflow and
    # rolled out via terraform plan/apply.
    image = {
      repository = "socketdev/socket-registry-firewall"
      tag        = var.firewall_image_tag
      pullPolicy = "IfNotPresent"
    }

    # CPU-driven HPA. Target 60% rather than the chart's 70% so a CI burst
    # starts adding replicas before the running pods are already saturated —
    # scale-up has to wait on metrics, pod start, and (past node_min_count) a
    # node. maxReplicas is bounded by node_max_count, since one pod fills most
    # of a node at the requests below; asking for more would leave pods Pending.
    autoscaling = {
      enabled                        = true
      minReplicas                    = var.replica_count
      maxReplicas                    = var.max_replica_count
      targetCPUUtilizationPercentage = 60
    }

    # The load balancer holds idle keepalive connections to the backend for a
    # fixed 600s that GCP does not let you configure. The chart's default of 65s
    # means nginx closes an idle connection the LB still considers usable; when a
    # request races that close the client gets a 503
    # (backend_connection_closed_before_data_sent_to_client — the top entry in
    # this deployment's LB logs). Google's documented fix is a backend keepalive
    # above 600s, recommended 620.
    keepaliveTimeout = 620

    # Google's guidance for the same error on GKE NEG backends:
    # Tgrace > TpreStop + Tdrain + Tbuffer, at least 210s. Tdrain is the 60s
    # connection draining in tls.tf.
    #
    # TpreStop is 0 here because the chart exposes no preStop hook, so nothing
    # holds the pod open for the ~120s the endpoint can take to leave the NEG.
    # In-flight requests are covered, but requests the LB sends in that window
    # still land on a shutting-down pod. That residue is the reason to expect
    # this error to shrink rather than vanish.
    terminationGracePeriodSeconds = 210

    # The socket-registry-firewall image runs as UID 1001, but the
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

    # failOpen=true: when the Socket API circuit breaker trips (or the API is
    # unreachable), allow packages that have a cached verdict and fall back to
    # allow for cache misses. Pair with Redis stale-while-revalidate below so
    # the common case serves the last known-good decision instead of blocking.
    # failOpenUnscanned stays false — unknown/unscanned packages are still blocked.
    socket = {
      existingSecret    = kubernetes_secret.socket_api_token.metadata[0].name
      existingSecretKey = "SOCKET_SECURITY_API_TOKEN"
      failOpen          = true
      failOpenUnscanned = false
      # Fresh window for Socket API verdicts (seconds). After this, entries are
      # stale and revalidated; Redis retains them until redis.ttl.
      cacheTtl = 600
    }

    # Shared Redis cache (Memorystore). Fresh for cacheTtl, then stale until
    # redis.ttl — on API/breaker failure the firewall serves the stale verdict.
    redis = {
      enabled                 = true
      host                    = google_redis_instance.verdict_cache.host
      port                    = 6378 # Memorystore TLS port
      ttl                     = 86400
      existingSecret          = kubernetes_secret.redis_auth.metadata[0].name
      existingSecretKey       = "REDIS_PASSWORD"
      ssl                     = true
      sslVerify               = true
      sslServerName           = google_redis_instance.verdict_cache.host
      sslCaCertExistingSecret = kubernetes_secret.redis_ca.metadata[0].name
    }

    # Circuit breaker is not a first-class chart value yet; pass via the
    # raw-config escape hatch (top-level socket.yml section).
    extraConfig = {
      resilience = {
        circuit_breaker = {
          enabled = true
        }
      }
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
      } : {
      type = "LoadBalancer"
    }

    # The Socket Firewall container always serves HTTPS on its internal port and
    # its health check is `curl -fk https://localhost:8443/health`, so it needs a
    # cert present or the listener (and the probe) never come up. With GCP-managed
    # TLS the Gateway still terminates the *public* trusted certificate; the pod
    # keeps a self-signed cert only for the internal Gateway->pod hop (ClusterIP,
    # not externally reachable).
    tls = {
      generateSelfSigned = true
    }

    # The old 768Mi limit was the value the chart explicitly calls out as
    # OOM-killing on large package indexes, and 512Mi requests put the pod in
    # Burstable QoS, so it was also an eviction candidate under node pressure.
    # An OOM kill or eviction drops every in-flight request on that pod, which
    # reaches the client as a 503. Memory request == limit so the pod never sits
    # above its request and is not ranked for eviction.
    #
    # Still below the chart's 4 CPU / 8Gi default: that assumes metadata
    # filtering (disabled here) and would not schedule on the current nodes.
    # These requests fit one pod per e2-standard-2 node alongside system pods,
    # which also keeps replicas on separate nodes.
    resources = {
      requests = {
        cpu    = "750m"
        memory = "3Gi"
      }
      limits = {
        cpu    = "1500m"
        memory = "3Gi"
      }
    }

    # Default is 4 workers. With a 1.5-CPU limit that oversubscribes the cgroup
    # quota and the workers throttle each other, which shows up first as slow
    # /health responses — enough of them and the LB drops the backend and
    # returns 503 while the pod is still Ready.
    nginx = {
      workerProcesses = 2
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
    kubernetes_secret.redis_auth,
    kubernetes_secret.redis_ca,
    google_compute_firewall.allow_redis_egress,
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
