# ---------------------------------------------------------------------------
# Memorystore Redis — shared Socket API verdict cache
# ---------------------------------------------------------------------------
# Multi-replica firewall pods need a shared cache so a tripped circuit breaker
# can serve the last known-good verdict (stale-while-revalidate) instead of
# blocking. In-cluster Redis would require Binary Authorization allowlisting
# of a Redis image; Memorystore avoids that and keeps Redis off the pod
# security boundary.
#
# Connectivity: PRIVATE_SERVICE_ACCESS on the firewall VPC. AUTH + in-transit
# TLS (server authentication) so the AUTH string and CA are mounted into the
# firewall pods via Kubernetes secrets.
# ---------------------------------------------------------------------------

resource "google_compute_global_address" "redis_psa" {
  name          = "${var.cluster_name}-redis-psa"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 24
  network       = google_compute_network.main.id
  project       = var.project_id

  depends_on = [google_project_service.required]
}

resource "google_service_networking_connection" "redis_psa" {
  network                 = google_compute_network.main.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.redis_psa.name]

  depends_on = [google_project_service.required]
}

resource "google_redis_instance" "verdict_cache" {
  name               = "${var.cluster_name}-verdict-cache"
  display_name       = "Socket Firewall verdict cache"
  tier               = "BASIC"
  memory_size_gb     = var.redis_memory_size_gb
  region             = var.region
  location_id        = var.zone
  redis_version      = "REDIS_7_0"
  authorized_network = google_compute_network.main.id
  connect_mode       = "PRIVATE_SERVICE_ACCESS"
  auth_enabled       = true
  # SERVER_AUTHENTICATION enables TLS on port 6378 and exposes a per-instance
  # CA that the firewall mounts via redis.sslCaCertExistingSecret.
  transit_encryption_mode = "SERVER_AUTHENTICATION"

  labels = {
    app  = "socket-firewall"
    env  = "prod"
    team = "team-security-2"
  }

  depends_on = [
    google_service_networking_connection.redis_psa,
    google_project_service.required,
  ]
}

# AUTH string for the Helm chart (REDIS_PASSWORD env → redis-password secret).
resource "kubernetes_secret" "redis_auth" {
  metadata {
    name      = "socket-firewall-redis-auth"
    namespace = kubernetes_namespace.socket_firewall.metadata[0].name
  }

  data = {
    REDIS_PASSWORD = google_redis_instance.verdict_cache.auth_string
  }

  type = "Opaque"

  depends_on = [
    kubernetes_namespace.socket_firewall,
    google_redis_instance.verdict_cache,
  ]
}

# Memorystore in-transit encryption CA (private per-instance CA, not in the
# system trust store). Mounted by the chart at /etc/nginx/redis-tls/ca/ca.crt.
resource "kubernetes_secret" "redis_ca" {
  metadata {
    name      = "socket-firewall-redis-ca"
    namespace = kubernetes_namespace.socket_firewall.metadata[0].name
  }

  data = {
    "ca.crt" = google_redis_instance.verdict_cache.server_ca_certs[0].cert
  }

  type = "Opaque"

  depends_on = [
    kubernetes_namespace.socket_firewall,
    google_redis_instance.verdict_cache,
  ]
}
