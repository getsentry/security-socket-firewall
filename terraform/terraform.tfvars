project_id = "sentry-socket"
region     = "us-central1"
zone       = "us-central1-a"

terraformer      = "socket-firewall-tf-apply@sac-prod-sa.iam.gserviceaccount.com"
terraformer_plan = "socket-firewall-tf-plan@sac-prod-sa.iam.gserviceaccount.com"

cluster_name      = "socket-firewall"
node_machine_type = "e2-standard-2"
node_min_count    = 2
node_max_count    = 6

firewall_domain = "sfw.security.sentry.io."

replica_count      = 2
max_replica_count  = 6
helm_chart_version = "0.11.2"
firewall_image_tag = "2.1.1"
