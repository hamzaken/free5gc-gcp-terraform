# shellcheck shell=bash
# Shared helpers for the scripts in this directory (sourced, not executed).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO_ROOT

# shellcheck source=scripts/lib/pins.sh
source "${REPO_ROOT}/scripts/lib/pins.sh"

CHARTS_DIR="${REPO_ROOT}/.charts/free5gc-helm"
INFRA_DIR="${REPO_ROOT}/terraform/infra"
PLATFORM_DIR="${REPO_ROOT}/terraform/platform"
export CHARTS_DIR INFRA_DIR PLATFORM_DIR

if [[ -t 2 ]]; then
  _c_red=$'\033[31m'; _c_grn=$'\033[32m'; _c_ylw=$'\033[33m'; _c_off=$'\033[0m'
else
  _c_red=""; _c_grn=""; _c_ylw=""; _c_off=""
fi

log()  { printf '%s[INFO]%s %s\n' "${_c_grn}" "${_c_off}" "$*" >&2; }
warn() { printf '%s[WARN]%s %s\n' "${_c_ylw}" "${_c_off}" "$*" >&2; }
die()  { printf '%s[FAIL]%s %s\n' "${_c_red}" "${_c_off}" "$*" >&2; exit 1; }

require_cmd() {
  local c
  for c in "$@"; do
    command -v "${c}" >/dev/null 2>&1 || die "required command not found: ${c}"
  done
}

# Ask for an explicit "yes" before an action that costs money or deletes data.
# Set ASSUME_YES=1 only in automation that already has its own approval gate.
confirm() {
  local prompt="$1" reply
  if [[ "${ASSUME_YES:-0}" == "1" ]]; then
    warn "ASSUME_YES=1: skipping confirmation for: ${prompt}"
    return 0
  fi
  [[ -t 0 ]] || die "refusing to continue without a terminal to confirm: ${prompt}"
  read -r -p "${prompt} Type 'yes' to continue: " reply
  [[ "${reply}" == "yes" ]] || die "aborted by user"
}

# Read a top-level scalar "key: value" from a flat section of a YAML file we
# control (config/subscribers.yaml). Quotes are stripped; comments ignored.
yaml_scalar() {
  local file="$1" key="$2" value
  value="$(awk -v k="${key}" '
    /^[[:space:]]*#/ { next }
    {
      line = $0
      sub(/[[:space:]]+#.*$/, "", line)
      if (match(line, "^[[:space:]]+" k ":[[:space:]]*")) {
        v = substr(line, RLENGTH + 1)
        gsub(/^"|"$/, "", v)
        print v
        exit
      }
    }' "${file}")"
  [[ -n "${value}" ]] || die "could not read '${key}' from ${file}"
  printf '%s' "${value}"
}

# Terraform output from a root module, raw string.
tf_output() {
  terraform -chdir="$1" output -raw "$2"
}

# Print the IMSI list defined by a subscribers YAML file, one per line, using
# the same rules as terraform/modules/config (tests/test_imsi_consistency.sh
# checks that both implementations agree).
imsi_list() {
  local file="$1" count mcc mnc start plmn msin_len msin_start i
  count="$(yaml_scalar "${file}" count)"
  mcc="$(yaml_scalar "${file}" mcc)"
  mnc="$(yaml_scalar "${file}" mnc)"
  start="$(yaml_scalar "${file}" starting_imsi)"

  if ! [[ "${count}" =~ ^[0-9]+$ ]] || (( count < 1 || count > 1000 )); then
    die "invalid count: ${count}"
  fi
  [[ "${mcc}" =~ ^[0-9]{3}$ ]] || die "invalid mcc: ${mcc}"
  [[ "${mnc}" =~ ^[0-9]{2,3}$ ]] || die "invalid mnc: ${mnc}"
  [[ "${start}" =~ ^[0-9]{15}$ ]] || die "invalid starting_imsi: ${start}"
  plmn="${mcc}${mnc}"
  [[ "${start}" == "${plmn}"* ]] || die "starting_imsi must start with ${plmn}"

  msin_len=$(( 15 - ${#plmn} ))
  # Force base 10: an MSIN such as 0000000099 would otherwise be read as octal.
  msin_start=$(( 10#${start:${#plmn}} ))
  (( msin_start + count - 1 < 10 ** msin_len )) || die "starting_imsi + count overflows the MSIN"

  for (( i = 0; i < count; i++ )); do
    printf '%s%0*d\n' "${plmn}" "${msin_len}" $(( msin_start + i ))
  done
}

# terraform init, passing the GCS state bucket when a remote backend is used
# (backend.tf copied from backend.tf.example; TF_STATE_BUCKET set).
tf_init() {
  if [[ -n "${TF_STATE_BUCKET:-}" ]]; then
    terraform -chdir="$1" init -input=false -backend-config="bucket=${TF_STATE_BUCKET}" >/dev/null
  else
    terraform -chdir="$1" init -input=false >/dev/null
  fi
}

# kubeconfig entry for the cluster's IAM-authorised DNS endpoint.
get_credentials() {
  gcloud container clusters get-credentials "$(tf_output "${INFRA_DIR}" cluster_name)" \
    --zone "$(tf_output "${INFRA_DIR}" cluster_location)" \
    --project "$(tf_output "${INFRA_DIR}" project_id)" \
    --dns-endpoint >/dev/null 2>&1 \
    || warn "could not configure kubectl; run: $(tf_output "${INFRA_DIR}" get_credentials_command)"
}
