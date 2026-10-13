output "network_id" {
  description = "VPC self link / ID."
  value       = google_compute_network.this.id
}

output "network_name" {
  description = "VPC name."
  value       = google_compute_network.this.name
}

output "subnetwork_id" {
  description = "Node subnet ID."
  value       = google_compute_subnetwork.nodes.id
}

output "pods_range_name" {
  description = "Secondary range name for Pods."
  value       = google_compute_subnetwork.nodes.secondary_ip_range[0].range_name
}

output "services_range_name" {
  description = "Secondary range name for Services."
  value       = google_compute_subnetwork.nodes.secondary_ip_range[1].range_name
}
