variable "project_id" {
  description = "Existing GCP project ID to deploy into."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project_id))
    error_message = "project_id must be a valid GCP project ID."
  }
}

variable "region" {
  description = "GCP region. Defaults to Paris; check GKE and machine-type availability for other regions."
  type        = string
  default     = "europe-west9"
}

variable "zone" {
  description = "Zone for the zonal GKE cluster and its node pools. Must be in var.region."
  type        = string
  default     = "europe-west9-a"
}

variable "name_prefix" {
  description = "Prefix for all resource names."
  type        = string
  default     = "free5gc"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,18}[a-z0-9]$", var.name_prefix))
    error_message = "name_prefix must be 3-20 chars of lowercase letters, digits and hyphens."
  }
}

variable "labels" {
  description = "Extra labels applied to every resource that supports them."
  type        = map(string)
  default     = {}
}

# --- GKE ---------------------------------------------------------------------

variable "release_channel" {
  description = "GKE release channel. Node auto-upgrade is mandatory on release channels; see docs/troubleshooting.md for gtp5g implications."
  type        = string
  default     = "REGULAR"

  validation {
    condition     = contains(["RAPID", "REGULAR", "STABLE"], var.release_channel)
    error_message = "release_channel must be RAPID, REGULAR or STABLE."
  }
}

variable "min_gke_minor_version" {
  description = "Minimum GKE minor version (1.X). 33 is required by Secret Manager sync; SCTP on Dataplane V2 needs >= 1.32.2."
  type        = number
  default     = 33
}

variable "general_pool" {
  description = "Node pool for the control-plane NFs, MongoDB and UERANSIM."
  type = object({
    machine_type = optional(string, "e2-standard-4")
    node_count   = optional(number, 1)
    disk_size_gb = optional(number, 50)
    disk_type    = optional(string, "pd-balanced")
    spot         = optional(bool, false)
  })
  default = {}

  validation {
    condition     = var.general_pool.node_count >= 1 && var.general_pool.node_count <= 10
    error_message = "general_pool.node_count must be between 1 and 10."
  }
}

variable "upf_pool" {
  description = "Dedicated, tainted node pool for the UPF and the gtp5g kernel module (Secure Boot off, ip_forward sysctl allowed)."
  type = object({
    machine_type = optional(string, "e2-standard-2")
    node_count   = optional(number, 1)
    disk_size_gb = optional(number, 50)
    disk_type    = optional(string, "pd-balanced")
    spot         = optional(bool, false)
  })
  default = {}

  validation {
    condition     = var.upf_pool.node_count >= 1 && var.upf_pool.node_count <= 3
    error_message = "upf_pool.node_count must be between 1 and 3."
  }
}

variable "authorized_networks" {
  description = "Optional CIDRs allowed to reach the control plane private IP endpoint (e.g. a VPN range). Admin access normally uses the IAM-protected DNS endpoint and needs no entry here."
  type = list(object({
    cidr_block   = string
    display_name = string
  }))
  default = []
}

variable "enable_secrets_encryption" {
  description = "Encrypt Kubernetes Secrets in etcd with a Cloud KMS key (application-layer secrets encryption)."
  type        = bool
  default     = true
}

variable "enable_dockerhub_proxy" {
  description = "Create an Artifact Registry remote repository that proxies Docker Hub, and pull all images through it (avoids Docker Hub anonymous rate limits)."
  type        = bool
  default     = true
}

variable "logging_components" {
  description = "GKE logging components. WORKLOADS logs drive most of the logging cost."
  type        = list(string)
  default     = ["SYSTEM_COMPONENTS", "WORKLOADS"]
}

variable "enable_vpc_flow_logs" {
  description = "Enable VPC flow logs on the subnet (useful for debugging, adds logging cost)."
  type        = bool
  default     = false
}

variable "deletion_protection" {
  description = "Terraform-level deletion protection on the cluster. Off by default because this is a disposable lab; scripts/destroy.sh asks for confirmation."
  type        = bool
  default     = false
}

# --- Kubernetes identities referenced by IAM (must match the platform stage) --

variable "free5gc_namespace" {
  description = "Namespace for free5GC (and MongoDB)."
  type        = string
  default     = "free5gc"
}

variable "ueransim_namespace" {
  description = "Namespace for UERANSIM."
  type        = string
  default     = "ueransim"
}
