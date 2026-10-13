variable "config_dir" {
  description = "Directory containing network.yaml, subscribers.yaml and versions.yaml."
  type        = string
}

variable "image_registry" {
  description = "Registry prefix for images (empty = docker.io)."
  type        = string
  default     = ""
}

variable "free5gc_release" {
  description = "Helm release name of free5GC (prefix of its Service names)."
  type        = string
  default     = "free5gc"
}

variable "free5gc_namespace" {
  description = "Namespace of free5GC."
  type        = string
  default     = "free5gc"
}
