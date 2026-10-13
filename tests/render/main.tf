# Offline render harness used by scripts/validate.sh. It has no providers and
# creates no resources: `terraform apply` here only evaluates outputs, which
# the script writes to .render/ for `helm lint` and `helm template`.

terraform {
  required_version = ">= 1.9.0"
}

variable "image_registry" {
  description = "Registry prefix to render with (empty = docker.io)."
  type        = string
  default     = ""
}

module "render" {
  source = "../../terraform/modules/render"

  config_dir     = "${path.root}/../../config"
  image_registry = var.image_registry
}

output "free5gc_values_common" {
  value = module.render.free5gc_values[0]
}

output "free5gc_values_main" {
  value = module.render.free5gc_values[1]
}

output "ueransim_values" {
  value = module.render.ueransim_values
}

output "subscriber_profile" {
  value = jsonencode(module.render.subscriber_profile)
}

output "image_refs" {
  value = module.render.image_refs
}
