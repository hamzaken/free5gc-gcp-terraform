# Authentication: Application Default Credentials only
# (`gcloud auth application-default login`, or GitHub OIDC + Workload Identity
# Federation in CI). No service-account key file is ever used or accepted.
provider "google" {
  project = var.project_id
  region  = var.region

  default_labels = merge(var.labels, {
    "managed-by" = "terraform"
    "stack"      = "free5gc-gcp-terraform"
  })
}
