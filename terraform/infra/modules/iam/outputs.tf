output "node_service_account_email" {
  description = "Email of the node service account."
  value       = google_service_account.nodes.email
}
