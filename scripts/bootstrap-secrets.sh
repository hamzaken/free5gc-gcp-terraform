#!/usr/bin/env bash
# Generate the runtime secrets and store them in Google Secret Manager.
#
#   - MongoDB root password and free5GC application password
#   - Per-subscriber authentication material: K and OPc (128-bit, random)
#
# Secret values are generated locally with `openssl rand`, kept only in shell
# variables and piped to `gcloud ... --data-file=-` on stdin. They are never
# written to disk, passed as command-line arguments, printed, or seen by
# Terraform. The secret containers themselves are created by terraform/infra.
#
# Idempotent: a secret that already has an enabled version is left untouched.
#
# Usage:
#   scripts/bootstrap-secrets.sh                        # create missing values
#   scripts/bootstrap-secrets.sh --rotate-subscribers   # new K/OPc for all UEs
#
# Requires: gcloud (authenticated), openssl, terraform (to read infra outputs).

# shellcheck source=scripts/lib/common.sh
source "$(dirname "$0")/lib/common.sh"

require_cmd gcloud openssl terraform

rotate_subscribers=0
for arg in "$@"; do
  case "${arg}" in
    --rotate-subscribers) rotate_subscribers=1 ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) die "unknown argument: ${arg}" ;;
  esac
done

project="$(tf_output "${INFRA_DIR}" project_id)"
region="$(tf_output "${INFRA_DIR}" region)"
secrets_json="$(terraform -chdir="${INFRA_DIR}" output -json secret_ids)"

# Regional secrets are served by a regional endpoint. Without this override
# gcloud sends regional resource names to the global API, which rejects them
# ("does not match the expected format [projects/*/secrets/*]"). Set for this
# process only; the user's gcloud configuration is not modified.
export CLOUDSDK_API_ENDPOINT_OVERRIDES_SECRETMANAGER="https://secretmanager.${region}.rep.googleapis.com/"

secret_id() {
  # Minimal JSON lookup without jq: {"key":"value",...}
  printf '%s' "${secrets_json}" | tr -d '{}"' | tr ',' '\n' | awk -F: -v k="$1" '$1 == k { print $2 }'
}

has_enabled_version() {
  local id="$1" out
  out="$(gcloud secrets versions list "${id}" --project="${project}" --location="${region}" \
    --filter="state:ENABLED" --limit=1 --format="value(name)" 2>/dev/null)" \
    || die "cannot list versions of ${id} (does it exist? did terraform/infra apply succeed?)"
  [[ -n "${out}" ]]
}

add_version() {
  # $1 = secret id; secret payload on stdin.
  gcloud secrets versions add "$1" --project="${project}" --location="${region}" \
    --data-file=- --quiet >/dev/null
}

# 32 hex chars = 128 bits. Hex-only passwords are URI- and sed-safe.
gen_password() { openssl rand -hex 24; }
gen_128bit()   { openssl rand -hex 16; }

# --- MongoDB passwords -------------------------------------------------------
for key in mongodb_root_password mongodb_app_password; do
  id="$(secret_id "${key}")"
  [[ -n "${id}" ]] || die "secret id for ${key} not found in terraform/infra outputs"
  if has_enabled_version "${id}"; then
    log "${id}: already set, leaving unchanged"
  else
    gen_password | tr -d '\n' | add_version "${id}"
    log "${id}: generated and stored"
  fi
done

# --- Subscriber credentials --------------------------------------------------
# Same IMSI derivation as terraform/modules/config (leading zeros preserved).
# (Portable to the bash 3.2 shipped with macOS: no mapfile, no negative index.)
imsis=()
while IFS= read -r line; do imsis+=("${line}"); done < <(imsi_list "${REPO_ROOT}/config/subscribers.yaml")
count="${#imsis[@]}"
(( count > 0 )) || die "no IMSIs generated from config/subscribers.yaml"

sub_id="$(secret_id subscriber_credentials)"
if has_enabled_version "${sub_id}" && (( rotate_subscribers == 0 )); then
  log "${sub_id}: already set, leaving unchanged (use --rotate-subscribers to regenerate)"
else
  if (( rotate_subscribers == 1 )); then
    warn "Rotating K/OPc for all ${count} subscribers. After this, run:"
    warn "  scripts/deploy.sh --reprovision   (updates MongoDB and restarts the UEs)"
    confirm "Generate new subscriber keys in ${sub_id}?"
  fi
  {
    printf '# imsi k opc  (generated %s; do not edit by hand)\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    for imsi in "${imsis[@]}"; do
      printf '%s %s %s\n' "${imsi}" "$(gen_128bit)" "$(gen_128bit)"
    done
  } | add_version "${sub_id}"
  log "${sub_id}: stored credentials for ${count} subscribers (${imsis[0]} .. ${imsis[count - 1]})"
fi

log "Secret bootstrap complete. Values were never written to disk or printed."
