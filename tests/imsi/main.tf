# Harness for tests/test_imsi_consistency.sh: exposes the IMSI list computed
# by terraform/modules/config for a given subscribers file. No providers.

terraform {
  required_version = ">= 1.9.0"
}

variable "subscribers_file" {
  type = string
}

module "config" {
  source = "../../terraform/modules/config"

  config_dir       = "${path.root}/../../config"
  subscribers_file = var.subscribers_file
}

output "imsis" {
  value = join("\n", module.config.subscribers.imsis)
}
