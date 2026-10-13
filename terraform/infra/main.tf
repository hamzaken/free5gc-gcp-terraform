# Stage 1 - infrastructure: VPC, NAT, GKE cluster + node pools, IAM,
# Artifact Registry proxy and Secret Manager containers.
#
# Stage 2 (terraform/platform) deploys the Kubernetes workloads. The two
# stages have separate state so the Kubernetes/Helm providers never need a
# cluster that does not exist yet (plan) or no longer exists (destroy).

module "config" {
  source = "../modules/config"

  config_dir = "${path.root}/../../config"
  # Both pools at full size plus one surge node each during upgrades.
  max_node_count = var.general_pool.node_count + var.upf_pool.node_count + 2
}

locals {
  name = var.name_prefix

  apis = toset([
    "compute.googleapis.com",
    "container.googleapis.com",
    "iam.googleapis.com",
    "secretmanager.googleapis.com",
    "cloudkms.googleapis.com",
    "artifactregistry.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
  ])
}

resource "google_project_service" "apis" {
  for_each = local.apis

  project = var.project_id
  service = each.value

  # Never disable APIs on destroy: other workloads in the project may use them.
  disable_on_destroy         = false
  disable_dependent_services = false
}

module "network" {
  source = "./modules/network"

  name             = local.name
  region           = var.region
  node_cidr        = module.config.network.node_cidr
  pod_cidr         = module.config.network.pod_cidr
  service_cidr     = module.config.network.service_cidr
  enable_flow_logs = var.enable_vpc_flow_logs

  depends_on = [google_project_service.apis]
}

module "iam" {
  source = "./modules/iam"

  name       = local.name
  project_id = var.project_id

  depends_on = [google_project_service.apis]
}

module "registry" {
  source = "./modules/registry"
  count  = var.enable_dockerhub_proxy ? 1 : 0

  name                       = local.name
  region                     = var.region
  project_id                 = var.project_id
  node_service_account_email = module.iam.node_service_account_email

  depends_on = [google_project_service.apis]
}

module "gke" {
  source = "./modules/gke"

  name       = "${local.name}-gke"
  project_id = var.project_id
  region     = var.region
  zone       = var.zone

  network_id          = module.network.network_id
  subnetwork_id       = module.network.subnetwork_id
  pods_range_name     = module.network.pods_range_name
  services_range_name = module.network.services_range_name
  max_pods_per_node   = module.config.network.max_pods_per_node

  release_channel       = var.release_channel
  min_gke_minor_version = var.min_gke_minor_version
  general_pool          = var.general_pool
  upf_pool              = var.upf_pool

  node_service_account_email = module.iam.node_service_account_email
  authorized_networks        = var.authorized_networks
  enable_secrets_encryption  = var.enable_secrets_encryption
  logging_components         = var.logging_components
  deletion_protection        = var.deletion_protection

  depends_on = [google_project_service.apis]
}

module "secrets" {
  source = "./modules/secrets"

  name           = local.name
  project_id     = var.project_id
  project_number = module.gke.project_number
  region         = var.region
  workload_pool  = module.gke.workload_pool
  secret_sync_namespaces = {
    free5gc  = var.free5gc_namespace
    ueransim = var.ueransim_namespace
  }

  # The Workload Identity pool (<project>.svc.id.goog) is created
  # asynchronously with the cluster; binding a principal from it too early
  # fails with "Identity Pool does not exist". Waiting for the whole GKE
  # module (node pools take minutes) gives it time to appear.
  depends_on = [google_project_service.apis, module.gke]
}
