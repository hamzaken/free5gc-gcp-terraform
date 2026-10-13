#!/usr/bin/env bash
# Tear everything down, in reverse order, with explicit confirmation.
#
#   1. platform  Helm releases, Job, SecretSync, namespaces. Deleting the
#                namespaces deletes the MongoDB PVC, so the GKE CSI driver
#                deletes its Persistent Disk while the cluster still exists.
#   2. infra     GKE cluster, node pools, VPC, NAT, registry, IAM, and the
#                Secret Manager secrets (subscriber keys are destroyed).
#   3. checks    lists any leftover disks that would still be billed.
#
# Not removable by design: the Cloud KMS key ring (GCP never deletes key
# rings; the key versions are scheduled for destruction and stop billing).
#
# Usage: scripts/destroy.sh [--platform-only]

# shellcheck source=scripts/lib/common.sh
source "$(dirname "$0")/lib/common.sh"

platform_only=0
[[ "${1:-}" == "--platform-only" ]] && platform_only=1

require_cmd terraform gcloud

project="$(tf_output "${INFRA_DIR}" project_id 2>/dev/null || true)"
[[ -n "${project}" ]] || die "no infra state found in terraform/infra; nothing to destroy (or state is elsewhere)"
cluster="$(tf_output "${INFRA_DIR}" cluster_name)"

warn "This permanently deletes the free5GC deployment in project '${project}':"
warn "  - all workloads and the MongoDB data (subscriber records)"
(( platform_only == 1 )) || warn "  - cluster '${cluster}', VPC, NAT, registry cache, and the Secret Manager secrets (K/OPc, passwords)"
confirm "Destroy?"

# --- 1. platform -------------------------------------------------------------
if terraform -chdir="${PLATFORM_DIR}" state list >/dev/null 2>&1 \
   && [[ -n "$(terraform -chdir="${PLATFORM_DIR}" state list 2>/dev/null)" ]]; then
  log "Destroying platform stage"
  TF_VAR_project_id="${project}"
  TF_VAR_region="$(tf_output "${INFRA_DIR}" region)"
  TF_VAR_cluster_dns_endpoint="$(tf_output "${INFRA_DIR}" cluster_dns_endpoint)"
  TF_VAR_image_registry="$(tf_output "${INFRA_DIR}" image_registry)"
  TF_VAR_secret_resource_names="$(terraform -chdir="${INFRA_DIR}" output -json secret_resource_names)"
  TF_VAR_free5gc_namespace="$(tf_output "${INFRA_DIR}" free5gc_namespace)"
  TF_VAR_ueransim_namespace="$(tf_output "${INFRA_DIR}" ueransim_namespace)"
  export TF_VAR_project_id TF_VAR_region TF_VAR_cluster_dns_endpoint TF_VAR_image_registry \
    TF_VAR_secret_resource_names TF_VAR_free5gc_namespace TF_VAR_ueransim_namespace
  [[ -f "${CHARTS_DIR}/PINNED_COMMIT" ]] || "${REPO_ROOT}/scripts/fetch-charts.sh"
  tf_init "${PLATFORM_DIR}"
  if ! terraform -chdir="${PLATFORM_DIR}" destroy -input=false -auto-approve; then
    warn "Platform destroy failed. If the cluster is already gone, its objects went with it;"
    warn "clear the stale state with:"
    warn "  terraform -chdir=terraform/platform state list | xargs -n1 terraform -chdir=terraform/platform state rm"
    die "stopping before infra destroy so no Persistent Disk is orphaned"
  fi
else
  log "Platform stage has no state; skipping"
fi

# PVC deletion is synchronous, but the CSI driver deletes the backing disk
# asynchronously. Wait for the PersistentVolumes to disappear, otherwise
# deleting the cluster next could orphan a billed disk.
if command -v kubectl >/dev/null 2>&1; then
  ns5g="$(tf_output "${INFRA_DIR}" free5gc_namespace)"
  for _ in $(seq 1 36); do
    pvs="$(kubectl get pv -o jsonpath="{range .items[?(@.spec.claimRef.namespace=='${ns5g}')]}{.metadata.name}{' '}{end}" 2>/dev/null || true)"
    [[ -z "${pvs// /}" ]] && break
    log "waiting for PersistentVolume deletion: ${pvs}"
    sleep 5
  done
  [[ -z "${pvs// /}" ]] || warn "PersistentVolumes still present: ${pvs} (check for leftover disks below)"
else
  warn "kubectl not found: cannot wait for disk deletion; check for leftover disks after destroy"
fi

(( platform_only == 1 )) && { log "Platform destroyed; infrastructure kept."; exit 0; }

# --- 2. infra ----------------------------------------------------------------
log "Destroying infrastructure stage"
tf_init "${INFRA_DIR}"
terraform -chdir="${INFRA_DIR}" destroy -input=false -auto-approve

# --- 3. leftovers ------------------------------------------------------------
log "Checking for billable leftovers"
leftover="$(gcloud compute disks list --project "${project}" \
  --filter="name~^pvc- AND -users:*" --format="value(name,zone.basename(),sizeGb)" 2>/dev/null || true)"
if [[ -n "${leftover}" ]]; then
  warn "Unattached PVC disks remain (still billed). Review and delete them if they belonged to this stack:"
  printf '  %s\n' "${leftover}" >&2
else
  log "No unattached PVC disks found."
fi
log "Done. The KMS key ring remains (cannot be deleted in GCP); its key versions are scheduled for destruction."
