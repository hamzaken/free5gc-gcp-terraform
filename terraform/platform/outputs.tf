output "free5gc_namespace" {
  description = "free5GC namespace."
  value       = var.free5gc_namespace
}

output "ueransim_namespace" {
  description = "UERANSIM namespace."
  value       = var.ueransim_namespace
}

output "subscriber_imsis" {
  description = "IMSIs provisioned (not secret)."
  value       = module.render.subscribers.imsis
}

output "provisioner_job" {
  description = "Name of the subscriber provisioning Job."
  value       = kubernetes_job_v1.provisioner.metadata[0].name
}

output "ue_pool" {
  description = "UE PDU-session address pool."
  value       = module.render.network.ue_cidr
}

output "plmn" {
  description = "Serving PLMN and slice."
  value = {
    plmn   = module.render.plmn.plmn
    snssai = "${module.render.plmn.sst}/${module.render.plmn.sd}"
    dnn    = module.render.plmn.dnn
  }
}
