variable "name" {
  description = "Name prefix."
  type        = string
}

variable "project_id" {
  description = "Project ID."
  type        = string
}

variable "project_number" {
  description = "Project number (used in Workload Identity principal identifiers)."
  type        = string
}

variable "region" {
  description = "Secret location; must equal the cluster region for GKE Secret Manager sync."
  type        = string
}

variable "workload_pool" {
  description = "Workload Identity pool of the cluster (<project>.svc.id.goog)."
  type        = string
}

variable "secret_sync_namespaces" {
  description = "Map of logical name (free5gc, ueransim) to Kubernetes namespace."
  type        = map(string)
}

variable "secret_sync_ksa" {
  description = "Name of the Kubernetes ServiceAccount used by SecretSync objects in each namespace."
  type        = string
  default     = "secret-sync"
}
