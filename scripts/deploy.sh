#!/usr/bin/env bash
# Two-stage deployment. Every stage that creates billable resources shows a
# Terraform plan and asks for an explicit "yes" before applying.
#
#   1. infra     terraform/infra    VPC, NAT, GKE, IAM, registry, secret containers
#   2. secrets   bootstrap-secrets  generate values into Secret Manager (no Terraform)
#   3. charts    fetch-charts       pinned upstream charts + patches
#   4. platform  terraform/platform namespaces, SecretSync, gtp5g, free5GC,
#                                   provisioning Job, UERANSIM
#
# Usage:
#   scripts/deploy.sh                    # all stages
#   scripts/deploy.sh --stage infra      # one stage: infra|secrets|charts|platform
#   scripts/deploy.sh --reprovision      # re-run subscriber provisioning, restart UEs
#
# Prerequisites: gcloud auth application-default login; terraform/infra/terraform.tfvars.

# shellcheck source=scripts/lib/common.sh
source "$(dirname "$0")/lib/common.sh"

stage="all"
reprovision=0
while (( $# > 0 )); do
  case "$1" in
    --stage) stage="${2:?--stage needs a value}"; shift 2 ;;
    --reprovision) reprovision=1; shift ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

require_cmd terraform gcloud git

preflight() {
  gcloud auth application-default print-access-token >/dev/null 2>&1 \
    || die "no Application Default Credentials. Run: gcloud auth application-default login"
  [[ -f "${INFRA_DIR}/terraform.tfvars" ]] \
    || die "missing terraform/infra/terraform.tfvars (copy terraform.tfvars.example)"
}

plan_and_apply() {
  # plan_and_apply <dir> <description> [extra terraform args...]
  local dir="$1" what="$2" planfile
  shift 2
  planfile="$(mktemp "${TMPDIR:-/tmp}/tfplan.XXXXXX")"
  tf_init "${dir}"
  terraform -chdir="${dir}" plan -input=false -out="${planfile}" "$@"
  if terraform -chdir="${dir}" show -json "${planfile}" | grep -Eq '"actions":\["(create|update|delete)'; then
    confirm "Apply the plan above (${what})? This may create or change BILLABLE resources."
    terraform -chdir="${dir}" apply -input=false "${planfile}"
  else
    log "No changes for ${what}"
  fi
  rm -f -- "${planfile:?}"
}

export_platform_vars() {
  TF_VAR_project_id="$(tf_output "${INFRA_DIR}" project_id)"
  TF_VAR_region="$(tf_output "${INFRA_DIR}" region)"
  TF_VAR_cluster_dns_endpoint="$(tf_output "${INFRA_DIR}" cluster_dns_endpoint)"
  TF_VAR_image_registry="$(tf_output "${INFRA_DIR}" image_registry)"
  TF_VAR_secret_sync_ksa="$(tf_output "${INFRA_DIR}" secret_sync_ksa)"
  TF_VAR_free5gc_namespace="$(tf_output "${INFRA_DIR}" free5gc_namespace)"
  TF_VAR_ueransim_namespace="$(tf_output "${INFRA_DIR}" ueransim_namespace)"
  # JSON objects are valid HCL, so the output can be passed through as-is.
  TF_VAR_secret_resource_names="$(terraform -chdir="${INFRA_DIR}" output -json secret_resource_names)"
  export TF_VAR_project_id TF_VAR_region TF_VAR_cluster_dns_endpoint TF_VAR_image_registry \
    TF_VAR_secret_sync_ksa TF_VAR_free5gc_namespace TF_VAR_ueransim_namespace TF_VAR_secret_resource_names
}

run_infra() {
  log "Stage 1/4: infrastructure"
  plan_and_apply "${INFRA_DIR}" "GKE infrastructure"
}

run_secrets() {
  log "Stage 2/4: secrets"
  "${REPO_ROOT}/scripts/bootstrap-secrets.sh"
}

run_charts() {
  log "Stage 3/4: charts"
  "${REPO_ROOT}/scripts/fetch-charts.sh"
}

run_platform() {
  log "Stage 4/4: platform"
  [[ -f "${CHARTS_DIR}/PINNED_COMMIT" ]] || run_charts
  export_platform_vars
  plan_and_apply "${PLATFORM_DIR}" "5G core workloads"
  get_credentials
  log "Deployment applied. Next: scripts/verify.sh"
}

run_reprovision() {
  log "Re-running subscriber provisioning"
  export_platform_vars
  plan_and_apply "${PLATFORM_DIR}" "re-provision subscribers" -replace=kubernetes_job_v1.provisioner
  get_credentials
  require_cmd kubectl
  local ns
  ns="$(tf_output "${INFRA_DIR}" ueransim_namespace)"
  kubectl -n "${ns}" rollout restart deployment/ueransim-ue
  kubectl -n "${ns}" rollout status deployment/ueransim-ue --timeout=300s
}

preflight
if (( reprovision == 1 )); then
  run_reprovision
  exit 0
fi

case "${stage}" in
  all) run_infra; run_secrets; run_charts; run_platform ;;
  infra) run_infra ;;
  secrets) run_secrets ;;
  charts) run_charts ;;
  platform) run_platform ;;
  *) die "unknown stage: ${stage}" ;;
esac
