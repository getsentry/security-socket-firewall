project_id = "sentry-socket"
region     = "us-central1"
zone       = "us-central1-a"

terraformer      = "socket-firewall-tf-apply@sac-prod-sa.iam.gserviceaccount.com"
terraformer_plan = "socket-firewall-tf-plan@sac-prod-sa.iam.gserviceaccount.com"

cluster_name      = "socket-firewall"
node_machine_type = "e2-standard-2"
node_count        = 2
node_min_count    = 2
node_max_count    = 3

firewall_domain = "sfw.security.sentry.io."

replica_count          = 2
enable_autoscaling     = false
helm_chart_version     = "0.2.4"
internal_load_balancer = false

# GCP-managed TLS (default when firewall_domain is set)
enable_gcp_managed_tls = true

# Override: use a pre-existing Kubernetes TLS secret instead
# tls_existing_secret = "socket-firewall-tls"
