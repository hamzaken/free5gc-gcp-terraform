# Pull-through cache for Docker Hub. All workload images are referenced by
# digest through this repository, so pulls are not subject to Docker Hub's
# anonymous rate limit once cached, and nodes only need access to Google APIs.

resource "google_artifact_registry_repository" "dockerhub" {
  #checkov:skip=CKV_GCP_84:Cache of public, digest-pinned Docker Hub images; Google-managed encryption at rest is sufficient.
  location      = var.region
  repository_id = "${var.name}-dockerhub"
  description   = "Remote repository proxying Docker Hub for ${var.name}"
  format        = "DOCKER"
  mode          = "REMOTE_REPOSITORY"

  remote_repository_config {
    description = "Docker Hub"
    docker_repository {
      public_repository = "DOCKER_HUB"
    }
  }
}

resource "google_artifact_registry_repository_iam_member" "nodes_reader" {
  location   = google_artifact_registry_repository.dockerhub.location
  repository = google_artifact_registry_repository.dockerhub.name
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${var.node_service_account_email}"
}
