# Secret containers and access policy ONLY. Terraform never creates secret
# versions: values are generated and uploaded by scripts/bootstrap-secrets.sh,
# so they never appear in Terraform plans or state.
#
# Regional secrets are used because GKE Secret Manager sync requires secret
# versions in the same region as the cluster.

locals {
  secrets = {
    mongodb_root_password  = "${var.name}-mongodb-root-password"
    mongodb_app_password   = "${var.name}-mongodb-app-password"
    subscriber_credentials = "${var.name}-subscriber-credentials"
  }

  # Workload Identity Federation for GKE principal of a Kubernetes
  # ServiceAccount. No Google service account and no key is involved.
  ksa_principal = {
    for k, ns in var.secret_sync_namespaces :
    k => "principal://iam.googleapis.com/projects/${var.project_number}/locations/global/workloadIdentityPools/${var.workload_pool}/subject/ns/${ns}/sa/${var.secret_sync_ksa}"
  }

  # Who may read what (least privilege per namespace).
  access = {
    "free5gc/mongodb_root_password"  = { ns = "free5gc", secret = "mongodb_root_password" }
    "free5gc/mongodb_app_password"   = { ns = "free5gc", secret = "mongodb_app_password" }
    "free5gc/subscriber_credentials" = { ns = "free5gc", secret = "subscriber_credentials" }
    "ueransim/subscriber_credentials" = {
      ns = "ueransim", secret = "subscriber_credentials"
    }
  }
}

resource "google_secret_manager_regional_secret" "this" {
  for_each = local.secrets

  secret_id = each.value
  location  = var.region

  labels = {
    "component" = "free5gc"
  }

  # Allows `terraform destroy` to remove the secrets (and their versions).
  # Destroying the stack therefore permanently deletes the subscriber keys.
  deletion_protection = false
}

resource "google_secret_manager_regional_secret_iam_member" "accessor" {
  for_each = local.access

  project   = var.project_id
  location  = google_secret_manager_regional_secret.this[each.value.secret].location
  secret_id = google_secret_manager_regional_secret.this[each.value.secret].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = local.ksa_principal[each.value.ns]
}
