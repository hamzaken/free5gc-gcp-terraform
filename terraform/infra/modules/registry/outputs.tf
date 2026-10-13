output "image_registry" {
  description = "Registry prefix to use in image references."
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.dockerhub.repository_id}"
}
