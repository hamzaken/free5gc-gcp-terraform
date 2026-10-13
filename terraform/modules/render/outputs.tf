output "free5gc_values" {
  description = "Ordered Helm values documents for the free5gc chart."
  value       = [yamlencode(local.nf_common_values), local.free5gc_values]
}

output "ueransim_values" {
  description = "Helm values document for the ueransim chart."
  value       = local.ueransim_values
}

output "subscriber_profile" {
  description = "Non-secret profile consumed by the provisioning Job."
  value       = local.subscriber_profile
}

output "image_refs" {
  description = "Fully qualified, digest-pinned image references."
  value       = local.image_refs
}

output "general_node_selector" {
  description = "nodeSelector for the general pool."
  value       = local.general_node_selector
}

output "upf_node_selector" {
  description = "nodeSelector for the UPF pool."
  value       = local.upf_node_selector
}

output "gtp5g" {
  description = "Pinned gtp5g settings."
  value       = module.config.gtp5g
}

output "subscribers" {
  description = "Subscriber profile and IMSIs."
  value       = module.config.subscribers
}

output "network" {
  description = "Validated network config."
  value       = module.config.network
}

output "plmn" {
  description = "PLMN/slice identifiers."
  value       = module.config.plmn
}
