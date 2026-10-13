# Values come from `terraform -chdir=terraform/infra output`. scripts/deploy.sh
# wires them automatically (TF_VAR_*); see terraform.tfvars.example for manual use.

variable "project_id" {
  description = "Project ID (infra output project_id)."
  type        = string
}

variable "region" {
  description = "Region (infra output region)."
  type        = string
}

variable "cluster_dns_endpoint" {
  description = "GKE DNS endpoint (infra output cluster_dns_endpoint)."
  type        = string
}

variable "image_registry" {
  description = "Registry prefix for images (infra output image_registry; empty = docker.io)."
  type        = string
  default     = ""
}

variable "secret_resource_names" {
  description = "Regional secret resource names by logical name (infra output secret_resource_names)."
  type = object({
    mongodb_root_password  = string
    mongodb_app_password   = string
    subscriber_credentials = string
  })
}

variable "secret_sync_ksa" {
  description = "ServiceAccount name bound in IAM for Secret Manager sync (infra output secret_sync_ksa)."
  type        = string
  default     = "secret-sync"
}

variable "free5gc_namespace" {
  description = "Namespace for free5GC; must match the infra stage."
  type        = string
  default     = "free5gc"
}

variable "ueransim_namespace" {
  description = "Namespace for UERANSIM; must match the infra stage."
  type        = string
  default     = "ueransim"
}

variable "charts_dir" {
  description = "Directory produced by scripts/fetch-charts.sh."
  type        = string
  default     = null
}

variable "deploy_ueransim" {
  description = "Deploy the UERANSIM gNB and UEs."
  type        = bool
  default     = true
}

variable "helm_timeout_seconds" {
  description = "Helm wait timeout. First installs pull images and build gtp5g, so allow time."
  type        = number
  default     = 1500
}
