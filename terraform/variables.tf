variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region"
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "GCP zone for the GKE cluster"
  type        = string
  default     = "us-central1-a"
}

variable "terraformer" {
  description = "Terraform apply service account email — has write permissions (e.g. name@project.iam.gserviceaccount.com)"
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]@[a-z][a-z0-9-]+\\.iam\\.gserviceaccount\\.com$", var.terraformer))
    error_message = "terraformer must be a valid GCP service account email ending in .iam.gserviceaccount.com"
  }
}

variable "terraformer_plan" {
  description = "Terraform plan service account email — read-only, used for plan-only CI runs (e.g. name@project.iam.gserviceaccount.com)"
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]@[a-z][a-z0-9-]+\\.iam\\.gserviceaccount\\.com$", var.terraformer_plan))
    error_message = "terraformer_plan must be a valid GCP service account email ending in .iam.gserviceaccount.com"
  }
}

variable "cluster_name" {
  description = "Name of the GKE cluster"
  type        = string
  default     = "socket-firewall"
}

variable "network_name" {
  description = "Name of the VPC network"
  type        = string
  default     = "socket-firewall-vpc"
}

variable "subnet_name" {
  description = "Name of the subnet"
  type        = string
  default     = "socket-firewall-subnet"
}

variable "subnet_cidr" {
  description = "CIDR range for the subnet"
  type        = string
  default     = "10.10.0.0/24"
}

variable "pods_cidr" {
  description = "Secondary CIDR range for pods"
  type        = string
  default     = "10.20.0.0/16"
}

variable "services_cidr" {
  description = "Secondary CIDR range for services"
  type        = string
  default     = "10.30.0.0/16"
}

variable "node_machine_type" {
  description = "Machine type for GKE nodes"
  type        = string
  default     = "e2-standard-2"
}

variable "node_min_count" {
  description = "Minimum number of nodes (autoscaling)"
  type        = number
  default     = 2
}

variable "node_max_count" {
  description = "Maximum number of nodes (autoscaling)"
  type        = number
  default     = 3
}

variable "kubernetes_version" {
  description = "Kubernetes version for the GKE cluster (empty = latest stable)"
  type        = string
  default     = ""
}

# --- Helm / Socket Firewall ---

variable "socket_api_token_secret_id" {
  description = "Secret Manager secret ID for the Socket.dev API token (e.g. socket-firewall-api-token)"
  type        = string
  default     = "socket-firewall-api-token"
}

variable "firewall_namespace" {
  description = "Kubernetes namespace for the socket-firewall release"
  type        = string
  default     = "socket-firewall"
}

variable "firewall_domain" {
  description = "Domain for path-based routing (e.g. sfw.company.com). Leave empty to skip ingress."
  type        = string
  default     = ""
}

variable "helm_chart_version" {
  description = "Version of the socket-firewall Helm chart"
  type        = string
}

variable "firewall_image_tag" {
  description = "Container image tag for socketdev/socket-registry-firewall (pinned for reproducible rollouts; bumped by check-firewall-versions workflow)"
  type        = string
}

variable "replica_count" {
  description = "Number of firewall pod replicas (ignored when HPA is enabled; used as a baseline for the chart)"
  type        = number
  default     = 2
}

variable "enable_network_policies" {
  description = "Apply default-deny-ingress NetworkPolicies in the firewall namespace (requires Calico enforcement on the cluster)"
  type        = bool
  default     = true
}

variable "path_routing_routes" {
  description = "Path-based routing rules for upstream registries"
  type = list(object({
    path     = string
    upstream = string
    registry = string
  }))
  default = [
    {
      path     = "/npm"
      upstream = "https://registry.npmjs.org"
      registry = "npm"
    },
    {
      path     = "/pypi"
      upstream = "https://pypi.org"
      registry = "pypi"
    },
    {
      path     = "/maven"
      upstream = "https://repo1.maven.org/maven2"
      registry = "maven"
    },
  ]
}
