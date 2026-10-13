variable "config_dir" {
  description = "Directory containing network.yaml, subscribers.yaml and versions.yaml."
  type        = string
}

variable "max_node_count" {
  description = "Largest number of nodes the cluster may reach, including surge nodes during upgrades. Used for IP capacity checks."
  type        = number
  default     = 0
}

variable "extra_reserved_cidrs" {
  description = "Additional ranges that must not overlap the configured ones (e.g. existing VPC subnets, on-prem routes)."
  type        = map(string)
  default     = {}
}

variable "image_registry" {
  description = "Registry prefix for all images (e.g. europe-west9-docker.pkg.dev/my-proj/dockerhub). Empty string pulls from docker.io."
  type        = string
  default     = ""
}

variable "network_file" {
  description = "Override path to network.yaml (tests)."
  type        = string
  default     = null
}

variable "subscribers_file" {
  description = "Override path to subscribers.yaml (tests)."
  type        = string
  default     = null
}

variable "versions_file" {
  description = "Override path to versions.yaml (tests)."
  type        = string
  default     = null
}
