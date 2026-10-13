# free5GC control plane, UPF and MongoDB from the official chart (pinned and
# patched by scripts/fetch-charts.sh).

resource "terraform_data" "charts_pinned" {
  input = try(trimspace(file("${local.charts_dir}/../PINNED_COMMIT")), "missing")

  lifecycle {
    precondition {
      condition     = fileexists("${local.charts_dir}/free5gc/Chart.yaml") && fileexists("${local.charts_dir}/ueransim/Chart.yaml")
      error_message = "Charts not found in ${local.charts_dir}. Run scripts/fetch-charts.sh first."
    }
  }
}

resource "helm_release" "free5gc" {
  name      = local.release_name
  namespace = kubernetes_namespace_v1.this["free5gc"].metadata[0].name
  chart     = "${local.charts_dir}/free5gc"

  # "helm upgrade --install": if a previous apply timed out, the release
  # exists in the cluster but not in Terraform state; a plain install would
  # then fail with "cannot re-use a name that is still in use".
  upgrade_install = true

  values = module.render.free5gc_values

  # Waits until every Pod is Ready: MongoDB (needs the synced Secret), the
  # NFs, and the UPF (needs gtp5g on a UPF node).
  wait            = true
  timeout         = var.helm_timeout_seconds
  atomic          = false
  cleanup_on_fail = false
  max_history     = 5

  depends_on = [
    terraform_data.charts_pinned,
    kubernetes_manifest.secret_sync,
    kubernetes_daemon_set_v1.gtp5g,
    # Policies first, so Pods never start in a half-configured network.
    kubernetes_network_policy_v1.default_deny_ingress,
    kubernetes_network_policy_v1.nf_mesh,
    kubernetes_network_policy_v1.mongodb,
    kubernetes_network_policy_v1.amf_n2,
    kubernetes_network_policy_v1.upf_n3,
  ]
}
