output "cluster_name" {
  description = "GKE cluster name"
  value       = google_container_cluster.main.name
}

output "kubeconfig_command" {
  description = "Command to configure kubectl via fleet Connect Gateway (the control plane has no public endpoint)"
  value       = "gcloud container fleet memberships get-credentials ${var.cluster_name} --project ${var.project_id}"
}

output "firewall_service_name" {
  description = "Kubernetes service name for the socket-firewall"
  value       = "socket-firewall"
}

output "firewall_namespace" {
  description = "Kubernetes namespace where the firewall is deployed"
  value       = kubernetes_namespace.socket_firewall.metadata[0].name
}

output "firewall_load_balancer_ip" {
  description = "External IP for HTTPS traffic (GKE Gateway when firewall_domain is set, otherwise the socket-firewall LoadBalancer service)"
  value = local.use_gcp_managed_tls ? try(
    [
      for addr in try(data.kubernetes_resource.firewall_gateway[0].object.status.addresses, []) :
      addr.value if try(addr.type, "") == "IPAddress"
    ][0],
    null,
    ) : try(
    data.kubernetes_service.socket_firewall.status[0].load_balancer[0].ingress[0].ip,
    null,
  )
}

output "tls_dns_authorization_record" {
  description = "CNAME record to publish in DNS so Google can validate and issue the managed certificate"
  value = local.use_gcp_managed_tls ? {
    name = google_certificate_manager_dns_authorization.firewall[0].dns_resource_record[0].name
    type = google_certificate_manager_dns_authorization.firewall[0].dns_resource_record[0].type
    data = google_certificate_manager_dns_authorization.firewall[0].dns_resource_record[0].data
  } : null
}

output "tls_certificate_name" {
  description = "Certificate Manager certificate resource name"
  value       = local.use_gcp_managed_tls ? google_certificate_manager_certificate.firewall[0].name : null
}

output "firewall_health_url" {
  description = "HTTPS health check URL for the socket-firewall"
  value = local.firewall_domain != "" ? format(
    "https://%s/health",
    local.firewall_domain,
  ) : null
}

output "firewall_domain" {
  description = "Normalized domain used for path-based routing"
  value       = local.firewall_domain != "" ? local.firewall_domain : null
}
