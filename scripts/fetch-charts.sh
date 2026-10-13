#!/usr/bin/env bash
# Fetch the official free5GC Helm charts at a pinned commit and apply the
# reproducible patches from helm/patches/ (see helm/patches/README.md).
#
# Result: .charts/free5gc-helm/charts/{free5gc,ueransim} (git-ignored).
# Safe to re-run: the checkout is rebuilt from scratch every time.
#
# Usage: scripts/fetch-charts.sh

# shellcheck source=scripts/lib/common.sh
source "$(dirname "$0")/lib/common.sh"

require_cmd git

parent="$(dirname "${CHARTS_DIR}")"
mkdir -p "${parent}"
work="$(mktemp -d "${parent}/.fetch.XXXXXX")"
trap 'rm -rf -- "${work:?}"' EXIT

log "Cloning ${FREE5GC_HELM_REPO} @ ${FREE5GC_HELM_TAG}"
git -c advice.detachedHead=false clone --quiet --depth 1 --branch "${FREE5GC_HELM_TAG}" \
  "${FREE5GC_HELM_REPO}" "${work}/free5gc-helm"

actual="$(git -C "${work}/free5gc-helm" rev-parse HEAD)"
[[ "${actual}" == "${FREE5GC_HELM_COMMIT}" ]] \
  || die "tag ${FREE5GC_HELM_TAG} now points to ${actual}, expected ${FREE5GC_HELM_COMMIT}. Refusing to continue; review upstream changes and update scripts/lib/pins.sh."

chart_version() {
  awk '/^version:/ { print $2; exit }' "$1/Chart.yaml"
}
[[ "$(chart_version "${work}/free5gc-helm/charts/free5gc")" == "${FREE5GC_CHART_VERSION}" ]] \
  || die "unexpected free5gc chart version"
[[ "$(chart_version "${work}/free5gc-helm/charts/ueransim")" == "${UERANSIM_CHART_VERSION}" ]] \
  || die "unexpected ueransim chart version"

for patch in "${REPO_ROOT}"/helm/patches/*.patch; do
  log "Applying $(basename "${patch}")"
  git -C "${work}/free5gc-helm" apply --check "${patch}" \
    || die "patch does not apply cleanly: ${patch}"
  git -C "${work}/free5gc-helm" apply "${patch}"
done

rm -rf -- "${work:?}/free5gc-helm/.git"
printf '%s\n' "${FREE5GC_HELM_COMMIT}" > "${work}/free5gc-helm/PINNED_COMMIT"

rm -rf -- "${CHARTS_DIR:?}"
mv "${work}/free5gc-helm" "${CHARTS_DIR}"
log "Charts ready in ${CHARTS_DIR#"${REPO_ROOT}/"}"
