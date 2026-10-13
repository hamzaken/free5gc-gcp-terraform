variable "name" {
  description = "Name prefix."
  type        = string
}

variable "region" {
  description = "Region for the subnet, router and NAT."
  type        = string
}

variable "node_cidr" {
  description = "Primary subnet range (nodes)."
  type        = string
}

variable "pod_cidr" {
  description = "Secondary range for Pods."
  type        = string
}

variable "service_cidr" {
  description = "Secondary range for Services."
  type        = string
}

variable "enable_flow_logs" {
  description = "Enable VPC flow logs on the subnet."
  type        = bool
  default     = false
}
