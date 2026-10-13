#!/usr/bin/env bash
# Static validation. Creates nothing in any cloud and needs no credentials.
#
#   1. terraform fmt / validate (all root modules)     6. helm lint + template
#   2. terraform test (config module unit tests)       7. rendered-manifest checks
#   3. IMSI derivation consistency (bash vs TF)        8. kubeconform (if present)
#   4. chart fetch + patch verification                9. shellcheck (if present)
#   5. offline render of the Helm values              10. gitleaks/trivy (if present)
#
# Usage: scripts/validate.sh [--refetch]
# Env:   HELM=/path/to/helm   STRICT=1 (fail when an optional tool is missing; CI)

# shellcheck source=scripts/lib/common.sh
source "$(dirname "$0")/lib/common.sh"

HELM="${HELM:-helm}"
STRICT="${STRICT:-0}"
refetch=0
[[ "${1:-}" == "--refetch" ]] && refetch=1

require_cmd terraform git python3
command -v "${HELM}" >/dev/null 2>&1 || die "helm not found (set HELM=/path/to/helm). Required version: ${HELM_VERSION}"
helm_v="$("${HELM}" version --short 2>/dev/null | cut -d+ -f1)"
[[ "${helm_v}" == "${HELM_VERSION}" ]] || warn "helm ${helm_v} differs from pinned ${HELM_VERSION}"

optional() {
  # optional <tool> : returns 0 if available; otherwise warns (or fails in STRICT mode).
  if command -v "$1" >/dev/null 2>&1; then return 0; fi
  if [[ "${STRICT}" == "1" ]]; then die "$1 is required in STRICT mode"; fi
  warn "$1 not installed: skipping its checks (they run in CI)"
  return 1
}

RENDER="${REPO_ROOT}/.render"
mkdir -p "${RENDER}"
cd "${REPO_ROOT}"

log "1/10 terraform fmt"
terraform fmt -check -recursive -diff terraform tests

log "1/10 terraform validate"
for dir in terraform/infra terraform/platform terraform/modules/config terraform/modules/render tests/render tests/imsi; do
  terraform -chdir="${dir}" init -backend=false -input=false >/dev/null
  terraform -chdir="${dir}" validate -no-color >/dev/null || { terraform -chdir="${dir}" validate; die "terraform validate failed in ${dir}"; }
done

log "2/10 terraform test (config module)"
terraform -chdir=terraform/modules/config test -no-color >"${RENDER}/tftest.log" 2>&1 \
  || { cat "${RENDER}/tftest.log"; die "terraform test failed"; }
grep -E '^(Success|Failure)' "${RENDER}/tftest.log" >&2

log "3/10 IMSI derivation consistency"
"${REPO_ROOT}/tests/test_imsi_consistency.sh"

log "4/10 charts"
if [[ "${refetch}" == "1" || ! -f "${CHARTS_DIR}/PINNED_COMMIT" ]]; then
  "${REPO_ROOT}/scripts/fetch-charts.sh"
fi
[[ "$(cat "${CHARTS_DIR}/PINNED_COMMIT")" == "${FREE5GC_HELM_COMMIT}" ]] \
  || die "stale charts in ${CHARTS_DIR}; re-run with --refetch"

log "5/10 render values (offline)"
terraform -chdir=tests/render init -input=false >/dev/null
terraform -chdir=tests/render apply -auto-approve -input=false -state="${RENDER}/render.tfstate" >/dev/null
for o in free5gc_values_common free5gc_values_main ueransim_values subscriber_profile; do
  terraform -chdir=tests/render output -state="${RENDER}/render.tfstate" -raw "${o}" >"${RENDER}/${o}.yaml"
done

log "6/10 helm lint + template"
f5=(-f "${RENDER}/free5gc_values_common.yaml" -f "${RENDER}/free5gc_values_main.yaml")
ue=(-f "${RENDER}/ueransim_values.yaml")
"${HELM}" lint "${CHARTS_DIR}/charts/free5gc" "${f5[@]}" >"${RENDER}/lint-free5gc.log" 2>&1 \
  || { cat "${RENDER}/lint-free5gc.log"; die "helm lint free5gc failed"; }
"${HELM}" lint "${CHARTS_DIR}/charts/ueransim" "${ue[@]}" >"${RENDER}/lint-ueransim.log" 2>&1 \
  || { cat "${RENDER}/lint-ueransim.log"; die "helm lint ueransim failed"; }
"${HELM}" template free5gc "${CHARTS_DIR}/charts/free5gc" -n free5gc "${f5[@]}" >"${RENDER}/free5gc.yaml"
"${HELM}" template ueransim "${CHARTS_DIR}/charts/ueransim" -n ueransim "${ue[@]}" >"${RENDER}/ueransim.yaml"
log "rendered $(grep -c '^kind:' "${RENDER}/free5gc.yaml") free5gc and $(grep -c '^kind:' "${RENDER}/ueransim.yaml") ueransim objects"

log "7/10 rendered-manifest checks"
python3 "${REPO_ROOT}/tests/check_rendered.py" "${RENDER}"

log "8/10 kubeconform"
if optional kubeconform; then
  kubeconform -strict -summary -ignore-missing-schemas -kubernetes-version 1.33.0 \
    "${RENDER}/free5gc.yaml" "${RENDER}/ueransim.yaml"
fi

log "9/10 shellcheck"
if optional shellcheck; then
  shellcheck -x scripts/*.sh scripts/lib/*.sh tests/*.sh kubernetes/gtp5g/*.sh
fi

log "10/10 secret and IaC scanning"
if optional gitleaks; then
  # Working tree (including uncommitted files); CI also scans the full history.
  gitleaks dir "${REPO_ROOT}" --no-banner --redact --config "${REPO_ROOT}/.gitleaks.toml"
fi
if optional trivy; then
  trivy config --quiet --exit-code 1 --severity HIGH,CRITICAL \
    --ignorefile "${REPO_ROOT}/.trivyignore" "${REPO_ROOT}/terraform"
fi

log "All static checks passed."
