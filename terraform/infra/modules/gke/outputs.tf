output "cluster_name" {
  description = "Cluster name."
  value       = google_container_cluster.this.name
}

output "cluster_location" {
  description = "Cluster location (zone)."
  value       = google_container_cluster.this.location
}

output "dns_endpoint" {
  description = "IAM-authorised DNS endpoint of the control plane."
  value       = google_container_cluster.this.control_plane_endpoints_config[0].dns_endpoint_config[0].endpoint
}

output "workload_pool" {
  description = "Workload Identity pool."
  value       = local.workload_pool
}

output "project_number" {
  description = "Project number."
  value       = data.google_project.this.number
}

output "node_pools" {
  description = "Node pool names."
  value       = [for p in google_container_node_pool.this : p.name]
}
