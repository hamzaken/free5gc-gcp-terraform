# UERANSIM gNB + UEs from the official chart (pinned and patched). Deployed
# only after the subscribers exist, so the first registrations succeed.

resource "helm_release" "ueransim" {
  count = var.deploy_ueransim ? 1 : 0

  name      = "ueransim"
  namespace = kubernetes_namespace_v1.this["ueransim"].metadata[0].name
  chart     = "${local.charts_dir}/ueransim"

  # "helm upgrade --install": if a previous apply timed out, the release
  # exists in the cluster but not in Terraform state; a plain install would
  # then fail with "cannot re-use a name that is still in use".
  upgrade_install = true

  values = [module.render.ueransim_values]

  wait        = true
  timeout     = 900
  max_history = 5

  depends_on = [
    kubernetes_job_v1.provisioner,
    kubernetes_manifest.secret_sync,
    kubernetes_network_policy_v1.ueransim_gnb,
  ]
}
