variable "name" {
  description = "Cluster name."
  type        = string
}

variable "project_id" {
  description = "Project ID."
  type        = string
}

variable "region" {
  description = "Region (KMS key ring location)."
  type        = string
}

variable "zone" {
  description = "Zone of the zonal cluster."
  type        = string
}

variable "network_id" {
  description = "VPC ID."
  type        = string
}

variable "subnetwork_id" {
  description = "Node subnet ID."
  type        = string
}

variable "pods_range_name" {
  description = "Secondary range name for Pods."
  type        = string
}

variable "services_range_name" {
  description = "Secondary range name for Services."
  type        = string
}

variable "max_pods_per_node" {
  description = "Default max Pods per node."
  type        = number
}

variable "release_channel" {
  description = "GKE release channel."
  type        = string
}

variable "min_gke_minor_version" {
  description = "Minimum acceptable GKE minor version."
  type        = number
}

variable "general_pool" {
  description = "General node pool settings."
  type = object({
    machine_type = string
    node_count   = number
    disk_size_gb = number
    disk_type    = string
    spot         = bool
  })
}

variable "upf_pool" {
  description = "UPF node pool settings."
  type = object({
    machine_type = string
    node_count   = number
    disk_size_gb = number
    disk_type    = string
    spot         = bool
  })
}

variable "node_service_account_email" {
  description = "Node service account."
  type        = string
}

variable "authorized_networks" {
  description = "CIDRs allowed on the control plane private IP endpoint."
  type = list(object({
    cidr_block   = string
    display_name = string
  }))
}

variable "enable_secrets_encryption" {
  description = "Enable KMS application-layer Secrets encryption."
  type        = bool
}

variable "logging_components" {
  description = "Logging components."
  type        = list(string)
}

variable "deletion_protection" {
  description = "Terraform deletion protection on the cluster."
  type        = bool
}
