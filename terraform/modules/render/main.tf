# Pure rendering module: turns the validated configuration into the Helm
# values documents and the provisioning profile. No providers, no resources,
# so scripts/validate.sh can render and `helm template` the exact values that
# terraform/platform will deploy, without a cluster.

module "config" {
  source = "../config"

  config_dir     = var.config_dir
  image_registry = var.image_registry
}

locals {
  repo_root = "${path.module}/../../.."

  images     = module.config.images.parts
  image_refs = module.config.images.refs
  plmn       = module.config.plmn
  subs       = module.config.subscribers

  general_node_selector = { "free5gc.io/pool" = "general" }
  upf_node_selector     = { "free5gc.io/pool" = "upf" }
  upf_tolerations = [{
    key      = "free5gc.io/upf"
    operator = "Equal"
    value    = "true"
    effect   = "NoSchedule"
  }]

  # Bitnami templates the image as <registry>/<repository>:<tag>@<digest>.
  mongodb_ref_parts = regex("^(.+)/(bitnamilegacy/mongodb):([^@]+)@(sha256:[0-9a-f]{64})$", local.image_refs.mongodb)
  mongodb_image = {
    registry   = local.mongodb_ref_parts[0]
    repository = local.mongodb_ref_parts[1]
    tag        = local.mongodb_ref_parts[2]
    digest     = local.mongodb_ref_parts[3]
  }

  # NF init containers template curl as <registry>/<image>:<tag>.
  curl_ref_parts = regex("^(.+)/([^/]+)$", local.images.curl.name)
  curl_image = {
    registry = local.curl_ref_parts[0]
    image    = local.curl_ref_parts[1]
    tag      = local.images.curl.tag
  }

  # Per-NF image pins, init-container images and placement, deep-merged by
  # Helm with the templated values file.
  control_plane_nfs = ["amf", "ausf", "chf", "nef", "nrf", "nssf", "pcf", "smf", "udm", "udr"]
  nf_common_values = {
    for nf in local.control_plane_nfs : "free5gc-${nf}" => {
      initcontainers = {
        curl    = local.curl_image
        busybox = { image = local.images.busybox.name, tag = local.images.busybox.tag }
      }
      (nf) = {
        image        = { name = local.images[nf].name, tag = local.images[nf].tag }
        nodeSelector = local.general_node_selector
      }
    }
  }

  free5gc_values = templatefile("${local.repo_root}/helm/free5gc-values.yaml.tftpl", {
    images                = local.images
    image_refs            = local.image_refs
    mongodb_image         = local.mongodb_image
    curl_image            = local.curl_image
    general_node_selector = local.general_node_selector
    upf_node_selector     = local.upf_node_selector
    upf_tolerations       = local.upf_tolerations
    ue_cidr               = local.plmn.ue_cidr
    ue_dns_ipv4           = local.plmn.ue_dns_ipv4
    mcc                   = local.plmn.mcc
    mnc                   = local.plmn.mnc
    sst                   = local.plmn.sst
    sd                    = local.plmn.sd
    dnn                   = local.plmn.dnn
    tac_hex               = local.plmn.tac_hex
    imsis                 = local.subs.imsis
    gtp5g_min             = module.config.gtp5g.upf_min_version
    gtp5g_max_exclusive   = module.config.gtp5g.upf_max_version_exclusive
  })

  ueransim_values = templatefile("${local.repo_root}/helm/ueransim-values.yaml.tftpl", {
    images                          = local.images
    free5gc_release                 = var.free5gc_release
    free5gc_namespace               = var.free5gc_namespace
    general_node_selector           = local.general_node_selector
    mcc                             = local.plmn.mcc
    mnc                             = local.plmn.mnc
    nci                             = local.plmn.nci
    gnb_id_length                   = local.plmn.gnb_id_length
    tac                             = local.plmn.tac
    sst                             = local.plmn.sst
    sd                              = local.plmn.sd
    dnn                             = local.plmn.dnn
    authentication_management_field = local.subs.authentication_management_field
    ue_count                        = local.subs.count
  })

  # Non-secret profile for the provisioning Job.
  subscriber_profile = {
    database                        = "free5gc"
    plmn                            = local.plmn.plmn
    sst                             = local.plmn.sst
    sd                              = local.plmn.sd
    snssai_hex                      = local.plmn.snssai_hex
    dnn                             = local.plmn.dnn
    imsis                           = local.subs.imsis
    authentication_method           = local.subs.authentication_method
    authentication_management_field = local.subs.authentication_management_field
    sequence_number                 = local.subs.sequence_number
    default_5qi                     = local.subs.default_5qi
    charging_method                 = local.subs.charging_method
    ambr                            = local.subs.ambr
  }
}
