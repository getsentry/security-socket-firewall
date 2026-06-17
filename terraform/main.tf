terraform {
  required_version = ">= 1.5"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 6.0"
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

# The control plane is private (enable_private_endpoint = true). Rather than
# dialing the private endpoint directly (which requires VPC/IAP network access),
# the Kubernetes-facing providers reach it through fleet Connect Gateway — a
# Google-fronted, IAM-authenticated proxy that rides the cluster's outbound
# connect agent. This works identically from a local machine (after `gcloud auth
# application-default login`) and from a WIF-authenticated CI runner, with no
# bastion, IAP tunnel, or public control-plane endpoint. The read-only plan SA
# uses the same path via roles/gkehub.gatewayReader.
#
# Connect Gateway terminates TLS with Google's public certificate, so no
# cluster_ca_certificate is supplied — only host + a short-lived access token.
locals {
  connect_gateway_host = "https://connectgateway.googleapis.com/v1/projects/${data.google_project.main.number}/locations/global/gkeMemberships/${google_gke_hub_membership.main.membership_id}"

  # Normalized firewall domain (trailing dot stripped) and the flag that gates
  # every GCP-managed TLS / Gateway resource. Defined here because both helm.tf
  # and tls.tf depend on them.
  firewall_domain     = trim(var.firewall_domain, ".")
  use_gcp_managed_tls = local.firewall_domain != ""
}

provider "kubernetes" {
  host  = local.connect_gateway_host
  token = data.google_client_config.default.access_token
}

provider "helm" {
  kubernetes {
    host  = local.connect_gateway_host
    token = data.google_client_config.default.access_token
  }
}

# kubectl_manifest is used for the Gateway API resources (kubernetes_manifest
# performs a live API call during `plan`, which fails before the cluster exists).
# lazy_load = true defers client construction to apply time, since the gateway
# host depends on the membership created in this same apply. apply_retry_count
# absorbs the brief window after membership creation before the connect agent
# is routable.
provider "kubectl" {
  host              = local.connect_gateway_host
  token             = data.google_client_config.default.access_token
  load_config_file  = false
  lazy_load         = true
  apply_retry_count = 5
}

data "google_client_config" "default" {}
