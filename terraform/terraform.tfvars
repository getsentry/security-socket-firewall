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

replica_count      = 2
helm_chart_version = "0.2.4"
firewall_image_tag = "1.1.159"
