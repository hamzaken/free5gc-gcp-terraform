# shellcheck shell=bash
# shellcheck disable=SC2034  # constants consumed by the scripts that source this file
# Pinned sources consumed by the shell tooling (sourced, not executed).
# Runtime image pins live in config/versions.yaml.

# Official free5GC Helm charts (free5gc + ueransim), release tag v4.2.2.
# The commit is verified after checkout so a moved tag is detected.
FREE5GC_HELM_REPO="https://github.com/free5gc/free5gc-helm.git"
FREE5GC_HELM_TAG="v4.2.2"
FREE5GC_HELM_COMMIT="0d0b4b392bbb1b099acb9a1b37c39e0647ff6d4c"

# Helm CLI used for local rendering/linting (must match CI).
HELM_VERSION="v3.21.4"

# Chart versions inside that commit (asserted by scripts/fetch-charts.sh).
FREE5GC_CHART_VERSION="1.1.7"
UERANSIM_CHART_VERSION="2.0.17"
