# Stage 2 - platform: namespaces, Secret Manager sync, gtp5g node preparation,
# free5GC, subscriber provisioning and UERANSIM, in that dependency order:
#
#   namespaces -> SecretSync -> gtp5g DaemonSet -> free5GC (Helm, waits for
#   Pods) -> provisioning Job (waits for completion) -> UERANSIM (Helm)

module "render" {
  source = "../modules/render"

  config_dir        = "${path.root}/../../config"
  image_registry    = var.image_registry
  free5gc_release   = "free5gc"
  free5gc_namespace = var.free5gc_namespace
}

locals {
  charts_dir   = coalesce(var.charts_dir, "${path.root}/../../.charts/free5gc-helm/charts")
  release_name = "free5gc"

  image_refs            = module.render.image_refs
  general_node_selector = module.render.general_node_selector
  upf_node_selector     = module.render.upf_node_selector
}

# --- Namespaces --------------------------------------------------------------
# Pod Security Admission: the UPF (NET_ADMIN, ip_forward sysctl), the UEs
# (NET_ADMIN, TUN devices) and the gtp5g loader (privileged init container)
# exceed the "baseline" profile, so these namespaces enforce "privileged" and
# warn/audit at "baseline" to keep violations visible. See docs/security.md.

resource "kubernetes_namespace_v1" "this" {
  for_each = {
    free5gc  = var.free5gc_namespace
    ueransim = var.ueransim_namespace
    gtp5g    = "gtp5g-system"
  }

  metadata {
    name = each.value
    labels = {
      "app.kubernetes.io/part-of"          = "free5gc-gcp-terraform"
      "pod-security.kubernetes.io/enforce" = "privileged"
      "pod-security.kubernetes.io/warn"    = "baseline"
      "pod-security.kubernetes.io/audit"   = "baseline"
    }
  }
}
