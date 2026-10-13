variable "name" {
  description = "Name prefix."
  type        = string
}

variable "region" {
  description = "Repository location."
  type        = string
}

variable "project_id" {
  description = "Project ID."
  type        = string
}

variable "node_service_account_email" {
  description = "Node service account granted read access."
  type        = string
}
