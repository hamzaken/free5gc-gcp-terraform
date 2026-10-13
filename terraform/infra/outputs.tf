# Consumed by terraform/platform (via terraform_remote_state or -var) and by
# the scripts. None of these values is secret.

output "project_id" {
  description = "Project ID."
  value       = var.project_id
}

output "region" {
  description = "Region."
  value       = var.region
}

output "cluster_name" {
  description = "GKE cluster name."
  value       = module.gke.cluster_name
}

output "cluster_location" {
  description = "GKE cluster zone."
  value       = module.gke.cluster_location
}

output "cluster_dns_endpoint" {
  description = "IAM-authorised DNS endpoint of the GKE control plane."
  value       = module.gke.dns_endpoint
}

output "image_registry" {
  description = "Registry prefix for images (empty = docker.io)."
  value       = var.enable_dockerhub_proxy ? module.registry[0].image_registry : ""
}

output "secret_ids" {
  description = "Regional Secret Manager secret IDs (containers only; values are added by scripts/bootstrap-secrets.sh)."
  value       = module.secrets.secret_ids
}

output "secret_resource_names" {
  description = "Full regional secret resource names."
  value       = module.secrets.secret_resource_names
}

output "secret_sync_ksa" {
  description = "Kubernetes ServiceAccount name authorised to read the secrets."
  value       = module.secrets.secret_sync_ksa
}

output "free5gc_namespace" {
  description = "free5GC namespace bound in IAM."
  value       = var.free5gc_namespace
}

output "ueransim_namespace" {
  description = "UERANSIM namespace bound in IAM."
  value       = var.ueransim_namespace
}

output "get_credentials_command" {
  description = "Configure kubectl through the DNS endpoint."
  value       = "gcloud container clusters get-credentials ${module.gke.cluster_name} --zone ${module.gke.cluster_location} --project ${var.project_id} --dns-endpoint"
}
