output "secret_ids" {
  description = "Regional secret IDs by logical name."
  value       = { for k, s in google_secret_manager_regional_secret.this : k => s.secret_id }
}

output "secret_resource_names" {
  description = "Full resource names (projects/<p>/locations/<r>/secrets/<id>) by logical name."
  value       = { for k, s in google_secret_manager_regional_secret.this : k => s.id }
}

output "secret_sync_ksa" {
  description = "Kubernetes ServiceAccount name expected by the IAM bindings."
  value       = var.secret_sync_ksa
}
