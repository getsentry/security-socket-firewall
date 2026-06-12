terraform {
  required_version = ">= 1.5"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.30"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.13"
    }
    kubectl = {
      source  = "alekc/kubectl"
      version = ">= 2.4.0, < 3.0.0"
    }
  }

  backend "gcs" {
    bucket = "sac-prod-tf--socket-firewall"
    prefix = "socket-firewall/state"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
}

# Operational note: the cluster uses a private control-plane endpoint
# (enable_private_endpoint = true) with only the IAP range authorized. The
# Kubernetes/Helm providers below — and the kubernetes_manifest resources —
# talk to that private endpoint, so `terraform apply` must run from inside the
# VPC or through an IAP tunnel to the API server. It will hang/fail from a
# runner with no network path to the private endpoint.
provider "kubernetes" {
  host                   = "https://${google_container_cluster.main.endpoint}"
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = base64decode(google_container_cluster.main.master_auth[0].cluster_ca_certificate)
}

provider "helm" {
  kubernetes {
    host                   = "https://${google_container_cluster.main.endpoint}"
    token                  = data.google_client_config.default.access_token
    cluster_ca_certificate = base64decode(google_container_cluster.main.master_auth[0].cluster_ca_certificate)
  }
}

# Gateway API manifests use kubectl_manifest instead of kubernetes_manifest:
# kubernetes_manifest performs a live API call during `plan`, which fails on a
# first apply because the cluster endpoint is still unknown. kubectl_manifest
# defers entirely to apply time.
#
# lazy_load = true is required because alekc/kubectl >= 2.3.0 validates its
# config eagerly during `plan`. Since host/token/cert come from the cluster
# created in this same apply (empty until apply), eager validation fails with
# "no configuration has been provided". lazy_load defers client construction to
# apply time, matching the hashicorp kubernetes/helm provider behavior.
provider "kubectl" {
  host                   = "https://${google_container_cluster.main.endpoint}"
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = base64decode(google_container_cluster.main.master_auth[0].cluster_ca_certificate)
  load_config_file       = false
  lazy_load              = true
}

data "google_client_config" "default" {}
