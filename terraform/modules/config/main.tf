# Pure configuration module: reads config/*.yaml, validates it and derives
# every value the infrastructure and Helm releases need. It has no providers
# and creates no resources, so it can be unit-tested offline with
# `terraform test` (see tests/).

locals {
  network_raw  = yamldecode(file(coalesce(var.network_file, "${var.config_dir}/network.yaml")))
  subs_raw     = yamldecode(file(coalesce(var.subscribers_file, "${var.config_dir}/subscribers.yaml"))).subscribers
  versions_raw = yamldecode(file(coalesce(var.versions_file, "${var.config_dir}/versions.yaml")))

  # ---------------------------------------------------------------------------
  # CIDR validation
  # ---------------------------------------------------------------------------
  cidrs = merge({
    node    = local.network_raw.gcp.node_cidr
    pod     = local.network_raw.gcp.pod_cidr
    service = local.network_raw.gcp.service_cidr
    ue      = local.network_raw.free5gc.ue_cidr
  }, var.extra_reserved_cidrs)

  # Valid IPv4 CIDR whose address is the network address (no host bits set).
  cidr_errors = [
    for k, c in local.cidrs :
    "${k}: '${c}' is not a canonical IPv4 CIDR (expected e.g. 10.0.0.0/16 with no host bits set)"
    if !(
      can(regex("^\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}/\\d{1,2}$", c)) &&
      can(cidrnetmask(c)) &&
      try(cidrhost(c, 0) == split("/", c)[0], false)
    )
  ]
  cidrs_valid = length(local.cidr_errors) == 0

  prefix = { for k, c in local.cidrs : k => try(tonumber(split("/", c)[1]), 0) }

  # Private address space GKE accepts for VPC-native ranges without extra
  # configuration: RFC 1918 plus RFC 6598 shared space.
  allowed_parents = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10"]

  # a contains b  <=>  prefix(a) <= prefix(b) and network(b masked to prefix(a)) == network(a)
  outside_private_space = [
    for k, c in local.cidrs :
    "${k}: '${c}' is outside the allowed private ranges (${join(", ", local.allowed_parents)})"
    if local.cidrs_valid && !anytrue([
      for p in local.allowed_parents :
      tonumber(split("/", p)[1]) <= local.prefix[k] &&
      cidrhost("${split("/", c)[0]}/${split("/", p)[1]}", 0) == split("/", p)[0]
    ])
  ]

  cidr_keys = sort(keys(local.cidrs))
  cidr_pairs = flatten([
    for i, a in local.cidr_keys : [
      for j, b in local.cidr_keys : { a = a, b = b } if j > i
    ]
  ])
  # Two CIDRs overlap iff they are equal when both are masked to the shorter prefix.
  overlap_errors = [
    for p in local.cidr_pairs :
    "${p.a} (${local.cidrs[p.a]}) overlaps ${p.b} (${local.cidrs[p.b]})"
    if local.cidrs_valid && (
      cidrhost("${split("/", local.cidrs[p.a])[0]}/${min(local.prefix[p.a], local.prefix[p.b])}", 0) ==
      cidrhost("${split("/", local.cidrs[p.b])[0]}/${min(local.prefix[p.a], local.prefix[p.b])}", 0)
    )
  ]

  # ---------------------------------------------------------------------------
  # GKE capacity checks
  # ---------------------------------------------------------------------------
  max_pods_per_node = local.network_raw.gcp.max_pods_per_node

  # GKE gives each node a Pod block of size 2^ceil(log2(2 * maxPods)), i.e.
  # prefix M = 31 - ceil(log2(maxPods)). Computed with exact powers of two.
  pods_log2           = try(min([for k in range(3, 10) : k if pow(2, k) >= local.max_pods_per_node]...), 9)
  per_node_pod_prefix = 31 - local.pods_log2

  pod_range_node_capacity = (
    local.per_node_pod_prefix >= local.prefix.pod ? pow(2, local.per_node_pod_prefix - local.prefix.pod) : 0
  )
  # First two and last two addresses of a primary range are reserved.
  node_range_capacity = pow(2, 32 - local.prefix.node) - 4

  capacity_errors = compact([
    local.max_pods_per_node >= 8 && local.max_pods_per_node <= 256 ? "" :
    "max_pods_per_node must be between 8 and 256 (got ${local.max_pods_per_node})",
    local.prefix.node <= 29 ? "" : "node_cidr must be /29 or larger (got /${local.prefix.node})",
    local.prefix.service >= 16 && local.prefix.service <= 28 ? "" :
    "service_cidr must be between /16 and /28 (got /${local.prefix.service})",
    local.pod_range_node_capacity >= var.max_node_count ? "" :
    "pod_cidr /${local.prefix.pod} only fits ${local.pod_range_node_capacity} nodes at ${local.max_pods_per_node} Pods/node (per-node /${local.per_node_pod_prefix}); ${var.max_node_count} needed including upgrade surge",
    local.node_range_capacity >= var.max_node_count ? "" :
    "node_cidr /${local.prefix.node} only has ${local.node_range_capacity} usable addresses; ${var.max_node_count} needed",
    pow(2, 32 - local.prefix.ue) - 2 >= local.subscriber_count ? "" :
    "ue_cidr /${local.prefix.ue} is too small for ${local.subscriber_count} UEs",
  ])

  network_errors = concat(
    local.cidr_errors, local.outside_private_space, local.overlap_errors,
    local.cidrs_valid ? local.capacity_errors : []
  )

  # ---------------------------------------------------------------------------
  # Subscriber / PLMN derivation
  # ---------------------------------------------------------------------------
  mcc              = tostring(local.subs_raw.mcc)
  mnc              = tostring(local.subs_raw.mnc)
  plmn             = "${local.mcc}${local.mnc}"
  starting_imsi    = tostring(local.subs_raw.starting_imsi)
  subscriber_count = local.subs_raw.count
  msin_length      = 15 - length(local.plmn)
  msin_start       = try(tonumber(substr(local.starting_imsi, length(local.plmn), local.msin_length)), -1)

  sst = local.subs_raw.sst
  sd  = lower(tostring(local.subs_raw.sd))
  dnn = tostring(local.subs_raw.dnn)
  tac = local.network_raw.ran.tac
  ambr = {
    ue_uplink        = local.subs_raw.ue_ambr_uplink
    ue_downlink      = local.subs_raw.ue_ambr_downlink
    session_uplink   = local.subs_raw.session_ambr_uplink
    session_downlink = local.subs_raw.session_ambr_downlink
  }

  ambr_pattern = "^[0-9]+(\\.[0-9]+)? (bps|Kbps|Mbps|Gbps|Tbps)$"

  subscriber_errors = compact([
    can(regex("^[0-9]{3}$", local.mcc)) ? "" : "mcc must be exactly 3 digits, quoted (got '${local.mcc}')",
    can(regex("^[0-9]{2,3}$", local.mnc)) ? "" : "mnc must be 2 or 3 digits, quoted (got '${local.mnc}')",
    can(regex("^[0-9]{15}$", local.starting_imsi)) ? "" : "starting_imsi must be exactly 15 digits, quoted",
    startswith(local.starting_imsi, local.plmn) ? "" : "starting_imsi '${local.starting_imsi}' must start with mcc+mnc '${local.plmn}'",
    local.subscriber_count >= 1 && local.subscriber_count <= 1000 && floor(local.subscriber_count) == local.subscriber_count ? "" :
    "count must be an integer between 1 and 1000",
    local.msin_start >= 0 && local.msin_start + local.subscriber_count - 1 < pow(10, local.msin_length) ? "" :
    "starting_imsi + count overflows the ${local.msin_length}-digit MSIN",
    local.sst >= 1 && local.sst <= 255 && floor(local.sst) == local.sst ? "" : "sst must be an integer in 1..255",
    can(regex("^[0-9a-f]{6}$", local.sd)) ? "" : "sd must be 6 hex digits, quoted (e.g. \"010203\")",
    can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", local.dnn)) ? "" :
    "dnn must be lowercase letters, digits and hyphens (no dots)",
    local.dnn == tostring(local.network_raw.free5gc.dnn) ? "" :
    "subscribers.dnn ('${local.dnn}') must equal network free5gc.dnn ('${local.network_raw.free5gc.dnn}')",
    contains(["5G_AKA", "EAP_AKA_PRIME"], local.subs_raw.authentication_method) ? "" :
    "authentication_method must be 5G_AKA or EAP_AKA_PRIME",
    can(regex("^[0-9a-fA-F]{4}$", local.subs_raw.authentication_management_field)) ? "" :
    "authentication_management_field must be 4 hex digits",
    can(regex("^[0-9a-fA-F]{12}$", local.subs_raw.sequence_number)) ? "" : "sequence_number must be 12 hex digits",
    contains(["Offline", "none"], local.subs_raw.charging_method) ? "" : "charging_method must be Offline or none",
    local.subs_raw.default_5qi >= 1 && local.subs_raw.default_5qi <= 255 ? "" : "default_5qi must be in 1..255",
    alltrue([for v in values(local.ambr) : can(regex(local.ambr_pattern, v))]) ? "" :
    "AMBR values must look like '1000 Mbps' (units bps|Kbps|Mbps|Gbps|Tbps)",
    local.tac >= 0 && local.tac <= 16777215 && floor(local.tac) == local.tac ? "" : "ran.tac must be an integer in 0..16777215",
    can(regex("^0x[0-9a-fA-F]{9}$", local.network_raw.ran.nci)) ? "" : "ran.nci must be a 36-bit hex value like 0x000000010",
    local.network_raw.ran.gnb_id_length >= 22 && local.network_raw.ran.gnb_id_length <= 32 ? "" : "ran.gnb_id_length must be in 22..32",
    can(regex("^\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}$", local.network_raw.free5gc.ue_dns_ipv4)) ? "" :
    "free5gc.ue_dns_ipv4 must be an IPv4 address",
    try(local.network_raw.interfaces.multus_enabled, false) == false ? "" :
    "interfaces.multus_enabled=true is not implemented in this release (see docs/networking.md)",
  ])

  subscribers_ok = length(local.subscriber_errors) == 0

  # Sequential IMSIs. MSIN arithmetic is done on the MSIN part only and
  # re-padded to its fixed width, so leading zeros are preserved.
  imsis = local.subscribers_ok ? [
    for i in range(local.subscriber_count) :
    format("%s%0${local.msin_length}d", local.plmn, local.msin_start + i)
  ] : []

  # free5GC encodes an S-NSSAI as 2 hex digits of SST + 6 hex digits of SD
  # (util.SnssaiModelsToHex) in UDR/PCF document keys.
  snssai_hex = local.subscribers_ok ? format("%02x%s", local.sst, local.sd) : ""
  tac_hex    = local.subscribers_ok ? format("%06x", local.tac) : ""

  # ---------------------------------------------------------------------------
  # Images
  # ---------------------------------------------------------------------------
  image_prefix = var.image_registry == "" ? "docker.io/" : "${trimsuffix(var.image_registry, "/")}/"
  image_refs   = { for k, v in local.versions_raw.images : k => "${local.image_prefix}${v}" }

  image_errors = [
    for k, v in local.versions_raw.images :
    "image '${k}' must be pinned as name:tag@sha256:<64 hex> (got '${v}')"
    if !can(regex("^[a-z0-9./_-]+:[A-Za-z0-9._-]+@sha256:[0-9a-f]{64}$", v))
  ]

  # Charts template images as "<name>:<tag>", so split "repo:tag@digest" into
  # name="repo" and tag="tag@digest". The result is a valid reference.
  image_ref_pattern = "^(.+):([^:/@]+@sha256:[0-9a-f]{64})$"
  image_parts = {
    for k, v in local.image_refs : k => {
      name = regex(local.image_ref_pattern, v)[0]
      tag  = regex(local.image_ref_pattern, v)[1]
    } if can(regex(local.image_ref_pattern, v))
  }
}
