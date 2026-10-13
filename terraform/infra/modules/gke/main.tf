data "google_project" "this" {
  project_id = var.project_id
}

data "google_container_engine_versions" "this" {
  location = var.zone
}

locals {
  channel_default = data.google_container_engine_versions.this.release_channel_default_version[var.release_channel]
  channel_minor   = tonumber(split(".", local.channel_default)[1])
  workload_pool   = "${var.project_id}.svc.id.goog"
}

# --- Application-layer Secrets encryption (Cloud KMS) -------------------------

resource "random_id" "kms_suffix" {
  count       = var.enable_secrets_encryption ? 1 : 0
  byte_length = 3
}

# Key rings cannot be deleted in GCP; a random suffix lets the stack be
# destroyed and re-created without name collisions.
resource "google_kms_key_ring" "gke" {
  count    = var.enable_secrets_encryption ? 1 : 0
  name     = "${var.name}-gke-${random_id.kms_suffix[0].hex}"
  location = var.region
}

resource "google_kms_crypto_key" "etcd" {
  #checkov:skip=CKV_GCP_82:prevent_destroy would block the documented clean teardown; key versions are scheduled for destruction, not deleted immediately.
  count           = var.enable_secrets_encryption ? 1 : 0
  name            = "etcd-secrets"
  key_ring        = google_kms_key_ring.gke[0].id
  rotation_period = "7776000s" # 90 days
  purpose         = "ENCRYPT_DECRYPT"
}

resource "google_kms_crypto_key_iam_member" "gke_agent" {
  count         = var.enable_secrets_encryption ? 1 : 0
  crypto_key_id = google_kms_crypto_key.etcd[0].id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:service-${data.google_project.this.number}@container-engine-robot.iam.gserviceaccount.com"
}

# --- Cluster -----------------------------------------------------------------

resource "google_container_cluster" "this" {
  #checkov:skip=CKV_GCP_12:NetworkPolicy is enforced natively by Dataplane V2 (ADVANCED_DATAPATH); the legacy network_policy block must not be set with it.
  #checkov:skip=CKV_GCP_69:GKE_METADATA is set on every managed node pool; the default pool is removed.
  #checkov:skip=CKV_GCP_61:Intranode visibility adds flow-log cost; opt-in for investigations (docs/security.md).
  #checkov:skip=CKV_GCP_65:Google Groups for RBAC requires a Google Workspace domain; access is via project IAM.
  #checkov:skip=CKV_GCP_66:Binary Authorization needs an attestation pipeline (out of scope); all images are pinned by digest instead.
  name     = var.name
  location = var.zone

  network    = var.network_id
  subnetwork = var.subnetwork_id

  # Node pools are managed separately below.
  remove_default_node_pool = true
  initial_node_count       = 1

  deletion_protection = var.deletion_protection

  # Also applied to the GCE resources GKE creates (VMs, disks), so costs can
  # be attributed. Provider default_labels are merged on top.
  resource_labels = {
    "component" = "free5gc"
  }

  release_channel {
    channel = var.release_channel
  }

  networking_mode = "VPC_NATIVE"
  ip_allocation_policy {
    cluster_secondary_range_name  = var.pods_range_name
    services_secondary_range_name = var.services_range_name
  }
  default_max_pods_per_node = var.max_pods_per_node

  # GKE Dataplane V2 (Cilium/eBPF): required for SCTP (N2/NGAP) on GKE and
  # enforces Kubernetes NetworkPolicy natively.
  datapath_provider = "ADVANCED_DATAPATH"

  # Private nodes; the public IP endpoint of the control plane is disabled.
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = true
  }

  # Administrators reach the API server through the DNS-based endpoint,
  # which is authorised by IAM (container.clusters.connect) instead of by
  # source IP. No public IP endpoint exists.
  control_plane_endpoints_config {
    dns_endpoint_config {
      allow_external_traffic = true
    }
  }

  master_authorized_networks_config {
    gcp_public_cidrs_access_enabled = false
    dynamic "cidr_blocks" {
      for_each = var.authorized_networks
      content {
        cidr_block   = cidr_blocks.value.cidr_block
        display_name = cidr_blocks.value.display_name
      }
    }
  }

  workload_identity_config {
    workload_pool = local.workload_pool
  }

  # Secret Manager CSI add-on + "sync as Kubernetes Secret" (GKE >= 1.33).
  secret_manager_config {
    enabled = true
  }
  secret_sync_config {
    enabled = true
  }

  dynamic "database_encryption" {
    for_each = var.enable_secrets_encryption ? [1] : []
    content {
      state    = "ENCRYPTED"
      key_name = google_kms_crypto_key.etcd[0].id
    }
  }

  enable_shielded_nodes = true

  master_auth {
    client_certificate_config {
      issue_client_certificate = false
    }
  }

  logging_config {
    enable_components = var.logging_components
  }

  monitoring_config {
    enable_components = ["SYSTEM_COMPONENTS"]
    managed_prometheus {
      enabled = false
    }
  }

  # Kubernetes security posture (configuration audit), free tier.
  security_posture_config {
    mode = "BASIC"
  }

  node_pool_defaults {
    node_config_defaults {
      insecure_kubelet_readonly_port_enabled = "FALSE"
    }
  }

  lifecycle {
    precondition {
      condition     = local.channel_minor >= var.min_gke_minor_version
      error_message = "The ${var.release_channel} channel default in ${var.zone} is ${local.channel_default}; GKE 1.${var.min_gke_minor_version}+ is required (Secret Manager sync, SCTP on Dataplane V2)."
    }
  }

  depends_on = [google_kms_crypto_key_iam_member.gke_agent]
}

# --- Node pools --------------------------------------------------------------

locals {
  pools = {
    general = {
      config = var.general_pool
      labels = { "free5gc.io/pool" = "general" }
      taints = []
      # Measured boot + Secure Boot: only signed kernel modules can load.
      secure_boot = true
      sysctls     = []
    }
    upf = {
      config = var.upf_pool
      labels = { "free5gc.io/pool" = "upf" }
      taints = [{ key = "free5gc.io/upf", value = "true", effect = "NO_SCHEDULE" }]
      # The out-of-tree gtp5g module is unsigned; with Secure Boot the Ubuntu
      # kernel enforces lockdown and refuses to load it. This exception is
      # confined to this dedicated, tainted pool.
      secure_boot = false
      # The upstream UPF chart sets net.ipv4.ip_forward in the Pod sysctls.
      sysctls = ["net.ipv4.ip_forward"]
    }
  }
}

resource "google_container_node_pool" "this" {
  #checkov:skip=CKV_GCP_68:Secure Boot is enabled on the general pool and deliberately disabled only on the dedicated, tainted UPF pool, where the unsigned gtp5g module must load.
  for_each = local.pools

  name       = each.key
  cluster    = google_container_cluster.this.id
  location   = var.zone
  node_count = each.value.config.node_count

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  upgrade_settings {
    strategy        = "SURGE"
    max_surge       = 1
    max_unavailable = 0
  }

  node_config {
    machine_type = each.value.config.machine_type
    disk_size_gb = each.value.config.disk_size_gb
    disk_type    = each.value.config.disk_type
    spot         = each.value.config.spot

    # Ubuntu (not COS): required for SCTP on Dataplane V2 and for building and
    # loading the gtp5g out-of-tree kernel module.
    image_type = "UBUNTU_CONTAINERD"

    service_account = var.node_service_account_email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]

    labels = each.value.labels

    dynamic "taint" {
      for_each = each.value.taints
      content {
        key    = taint.value.key
        value  = taint.value.value
        effect = taint.value.effect
      }
    }

    # Pods see the GKE metadata server (Workload Identity), never the node's
    # credentials or instance metadata.
    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    shielded_instance_config {
      enable_secure_boot          = each.value.secure_boot
      enable_integrity_monitoring = true
    }

    metadata = {
      "disable-legacy-endpoints" = "true"
    }

    kubelet_config {
      insecure_kubelet_readonly_port_enabled = "FALSE"
      allowed_unsafe_sysctls                 = each.value.sysctls
    }
  }

  lifecycle {
    ignore_changes = [
      # GKE manages versions through the release channel.
      version,
    ]
  }
}
