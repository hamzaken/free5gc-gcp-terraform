# Least-privilege identity for the GKE nodes. The default Compute Engine
# service account (Editor on the project) is never used.

resource "google_service_account" "nodes" {
  account_id   = "${var.name}-gke-nodes"
  display_name = "GKE nodes for ${var.name}"
  description  = "Minimal node identity: logs, metrics, image pulls. Workloads use Workload Identity instead."
}

# roles/container.defaultNodeServiceAccount bundles exactly what a node needs
# (log writing, metric writing, resource metadata, autoscaling metrics).
resource "google_project_iam_member" "nodes_default" {
  project = var.project_id
  role    = "roles/container.defaultNodeServiceAccount"
  member  = "serviceAccount:${google_service_account.nodes.email}"
}
