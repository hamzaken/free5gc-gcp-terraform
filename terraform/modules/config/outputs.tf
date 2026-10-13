# Every output carries the validation preconditions, so any consumer fails at
# plan time with a precise message before a single resource is created.

output "network" {
  description = "Validated network addressing."
  value = {
    node_cidr           = local.cidrs.node
    pod_cidr            = local.cidrs.pod
    service_cidr        = local.cidrs.service
    ue_cidr             = local.cidrs.ue
    max_pods_per_node   = local.max_pods_per_node
    per_node_pod_prefix = local.per_node_pod_prefix
    pod_node_capacity   = local.pod_range_node_capacity
    node_capacity       = local.node_range_capacity
    dnn                 = local.dnn
    ue_dns_ipv4         = local.network_raw.free5gc.ue_dns_ipv4
  }

  precondition {
    condition     = length(local.network_errors) == 0
    error_message = "Invalid config/network.yaml:\n  - ${join("\n  - ", local.network_errors)}"
  }
}

output "plmn" {
  description = "PLMN, slice and RAN identifiers in the encodings each component expects."
  value = {
    mcc            = local.mcc
    mnc            = local.mnc
    plmn           = local.plmn
    sst            = local.sst
    sd             = local.sd
    snssai_hex     = local.snssai_hex
    dnn            = local.dnn
    tac            = local.tac
    tac_hex        = local.tac_hex
    nci            = local.network_raw.ran.nci
    gnb_id_length  = local.network_raw.ran.gnb_id_length
    ue_dns_ipv4    = local.network_raw.free5gc.ue_dns_ipv4
    ue_cidr        = local.cidrs.ue
    serving_plmnid = local.plmn
  }

  precondition {
    condition     = local.subscribers_ok
    error_message = "Invalid config/subscribers.yaml or config/network.yaml:\n  - ${join("\n  - ", local.subscriber_errors)}"
  }
}

output "subscribers" {
  description = "Non-secret subscriber profile and the generated IMSI list."
  value = {
    count                           = local.subscriber_count
    imsis                           = local.imsis
    authentication_method           = local.subs_raw.authentication_method
    authentication_management_field = lower(local.subs_raw.authentication_management_field)
    sequence_number                 = lower(local.subs_raw.sequence_number)
    default_5qi                     = local.subs_raw.default_5qi
    charging_method                 = local.subs_raw.charging_method
    ambr                            = local.ambr
  }

  precondition {
    condition     = local.subscribers_ok
    error_message = "Invalid subscriber configuration:\n  - ${join("\n  - ", local.subscriber_errors)}"
  }
}

output "images" {
  description = "Fully qualified, digest-pinned image references, split for chart values."
  value = {
    refs  = local.image_refs
    parts = local.image_parts
  }

  precondition {
    condition     = length(local.image_errors) == 0
    error_message = "Invalid config/versions.yaml:\n  - ${join("\n  - ", local.image_errors)}"
  }
}

output "gtp5g" {
  description = "Pinned gtp5g source and the version window accepted by the UPF."
  value       = local.versions_raw.gtp5g
}

output "free5gc_version" {
  description = "Pinned free5GC release."
  value       = local.versions_raw.free5gc_version
}
