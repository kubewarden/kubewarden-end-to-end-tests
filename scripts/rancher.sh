#!/usr/bin/env bash
set -aeEuo pipefail
# trap 'echo "Error on ${BASH_SOURCE/$PWD/.}:${LINENO} $(sed -n "${LINENO} s/^\s*//p" $PWD/${BASH_SOURCE/$PWD})"' ERR

# ==================================================================================================
# Rancher Installation Script
#
# This script simplifies Rancher installation by:
# - Finding the latest available chart version based on constraints
# - Selecting the appropriate repository based on priority
# - Setting up a K3d cluster with compatible Kubernetes version
# - Installing cert-manager and Rancher with proper configuration
#
# RANCHER format: [repository][semver]
#  - repository: (prime|community|p|c)(alpha|rc)?
#    filters rancher repository (--regexp "<repository>.*/rancher")
#  - semversion: (*-0|2.11|2.12-0|2.12.0-alpha5) - https://github.com/Masterminds/semver?tab=readme-ov-file#checking-version-constraints
#    filters rancher version (--version <semver>)
#
# Examples: 2.11.2-rc1 | p2.11-0 | c2.12-0 | p* | c*-0
# ==================================================================================================

# Default: version=stable, repository=priority ordered (community > prime > ..)
RANCHER=${RANCHER:-}

# Exclude versions if not explicitly requested
EXCLUDE_PATTERN="hotfix|debug|patch"

# Directory of the current script
BASEDIR=$(dirname "${BASH_SOURCE[0]}")

# ==================================================================================================
# Helper functions

. "$BASEDIR/../helpers/kubelib.sh"

create_k3d_cluster() {
    local rancher="$1"
    local k8s=""
    case "$rancher" in
        # Limit k8s version - https://www.suse.com/suse-rancher/support-matrix
        2.8*)  k8s="v1.28" ;; # v1.25 - v1.28
        2.9*)  k8s="v1.30" ;; # v1.27 - v1.30
        2.10*) k8s="v1.31" ;; # v1.28 - v1.31
        2.11*) k8s="v1.32" ;; # v1.30 - v1.32
    esac
    K3S="${K3S:-$k8s}" "$BASEDIR"/cluster_k3d.sh create "${@:2}"
}

# Add rancher repositories
helm_add_repositories() {
    ar() { helm repo ls | grep -q "^$1[[:space:]]" || helm repo add "$1" "$2"; }
    ar e2e-jetstack https://charts.jetstack.io
    ar e2e-rancher-prime https://charts.rancher.com/server-charts/prime
    ar e2e-rancher-primerc https://charts.optimus.rancher.io/server-charts/latest
    ar e2e-rancher-primealpha https://charts.optimus.rancher.io/server-charts/alpha
    ar e2e-rancher-community https://releases.rancher.com/server-charts/latest
    ar e2e-rancher-communityalpha https://releases.rancher.com/server-charts/alpha
    helm repo update e2e-rancher-prime e2e-rancher-primerc e2e-rancher-primealpha e2e-rancher-community e2e-rancher-communityalpha e2e-jetstack > /dev/null
    ar e2e-rancher-head-210 https://charts.optimus.rancher.io/server-charts/release-2.10
    ar e2e-rancher-head-211 https://charts.optimus.rancher.io/server-charts/release-2.11
    ar e2e-rancher-head-212 https://charts.optimus.rancher.io/server-charts/release-2.12
    helm repo update e2e-rancher-head-210 e2e-rancher-head-211 e2e-rancher-head-212 > /dev/null
}

# Find repository & highest version based on constraints
find_chart_by_constraints () {
    local query="$1"
    local q_repo q_ver charts

    # Parse input (RANCHER) to helm constraints (repo & semver)
    [[ $query =~ ^(prime|p|community|c|head|h)?(alpha|rc)?(.*)$ ]]
    case ${BASH_REMATCH[1]} in
        p) q_repo="prime${BASH_REMATCH[2]}" ;;
        c) q_repo="community${BASH_REMATCH[2]}" ;;
        h) q_repo="head" ;;
        *) q_repo="${BASH_REMATCH[1]}${BASH_REMATCH[2]}" ;;
    esac

    q_ver="${BASH_REMATCH[3]:-*}"
    # Head repo has only devel versions, autofix query head2.12 -> head2.12-0
    if [ "$q_repo" == "head" ]; then
        q_ver="${BASH_REMATCH[3]:-*-0}"
        [[ $q_ver =~ ^[0-9]\.[0-9]+$ ]] && q_ver+='-0'
    fi

    # Fix semver constraint for head 2.12<.0>-659a3fe3ac0d6ff0654717dcbd3161391d1f5662-head
    if [[ $q_ver =~ ^([0-9]+\.[0-9]+)-([0-9a-f]{40}-head)$ ]]; then
        q_ver="${BASH_REMATCH[1]}.0-${BASH_REMATCH[2]}"
    fi

    echo "QUERY: ${q_repo:--}:${q_ver:--}"

    # Find charts from Q_REPOs with version matching Q_VER, ordered by version
    [[ "$q_ver" =~ $EXCLUDE_PATTERN ]] || local expattern="$EXCLUDE_PATTERN"
    charts=$(helm search repo --fail-on-no-result -r "e2e-rancher-$q_repo.*/rancher" --version "$q_ver" --versions -o json |\
        jq -er --arg ex "${expattern:-}" '[.[] | select($ex == "" or (.version | test($ex) | not))] | unique_by(.name) | .[] | [.name, .version] | @tsv' | semsort -k2)

    # Same version can be in multiple repos (2.10.1 in prime, primerc, community)
    # Define repo priority: community > prime > communityalpha > primerc > primealpha
    CHART_VER=$(awk 'END {print $2}' <<< "$charts")
    CHART_REPO=$(grep -F "$CHART_VER" <<< "$charts" | sed -E '
        s|e2e-rancher-community/|1 &|
        s|e2e-rancher-prime/|2 &|
        s|e2e-rancher-communityalpha/|3 &|
        s|e2e-rancher-primerc/|4 &|
        s|e2e-rancher-primealpha/|5 &|
        s|e2e-rancher-head-[0-9]+/|6 &|' \
        | sort -nr | awk 'END {print $2}')

    echo "CHART: ${CHART_REPO:--}:${CHART_VER:--}"
}

# Wait for Rancher pods
wait_for_rancher() {
    for i in {1..20}; do
        output=$(kubectl get pods --no-headers -o wide -n cattle-system -l app=rancher-webhook | grep -vw Completed || echo 'Wait: cattle-system')$'\n'
        output+=$(kubectl get pods --no-headers -o wide -n cattle-system | grep -vw Completed || echo 'Wait: cattle-system')$'\n'
        output+=$(kubectl get pods --no-headers -o wide -n cattle-fleet-system | grep -vw Completed || echo 'Wait: cattle-fleet-system')$'\n'
        grep -vE '([0-9]+)/\1 +Running|^$' <<< "$output" || break
        [ "$i" -ne 20 ] && sleep 30 || {
            kubectl get pods -n cattle-system;
            kubectl get pods -n cattle-fleet-system;
            kubectl get events -n cattle-system;
            kubectl get events -n cattle-fleet-system;
            kubectl logs -n cattle-system -l app=rancher;
            kubectl logs -n cattle-system -l app=rancher-webhook;
            kubectl logs -n cattle-system -l app.kubernetes.io/component=controller;
            kubectl logs -n cattle-fleet-system -l app=fleet-controller;
            kubectl logs -n cattle-fleet-system -l app=gitjob;
            echo "Godot: pods not running";
            exit 1; }
    done
}

# ==================================================================================================
# Main script

[ -v DRY ] || { precheck rancher || exit 1; }

helm_add_repositories

# Find CHART_REPO & CHART_VER based on RANCHER
declare CHART_REPO CHART_VER
find_chart_by_constraints "$RANCHER"

# Create k3d cluster if it doesn't exist
if ! kubectl cluster-info &>/dev/null; then
    create_k3d_cluster "$CHART_VER" -p "443:443@loadbalancer"
    RANCHER_FQDN=127.0.0.1.nip.io
fi

# Get the FQDN for Rancher
RANCHER_FQDN=${RANCHER_FQDN:-$(kubectl get svc traefik -n kube-system -o jsonpath='{.status.loadBalancer.ingress[0].ip}').nip.io}
# Required for prime Alpha & RC
[[ $CHART_REPO =~ ^e2e-rancher-prime(alpha|rc) ]] && stgregistry=1

[ -v DRY ] && exit 0

# Install cert-manager
helm install --wait cert-manager e2e-jetstack/cert-manager -n cert-manager --create-namespace --set crds.enabled=true

# Install Rancher
helm search repo "$CHART_REPO" --version "$CHART_VER"
helm install rancher "$CHART_REPO" --version "$CHART_VER" \
    --namespace cattle-system --create-namespace \
    --set hostname="$RANCHER_FQDN" \
    --set bootstrapPassword=sa \
    --wait --timeout=15m \
    --set replicas=1 \
    ${stgregistry:+--set rancherImage=stgregistry.suse.com/rancher/rancher} \
    ${stgregistry:+--set extraEnv[0].name=CATTLE_AGENT_IMAGE} \
    ${stgregistry:+--set extraEnv[0].value=stgregistry.suse.com/rancher/rancher-agent:v$CHART_VER}
wait_for_rancher

# Check if Rancher has correct version and print URL
helm get metadata rancher -n cattle-system -o json | jq -r '.version' | grep -qx "$CHART_VER"
echo "Rancher URL: https://$RANCHER_FQDN/"

# command -v notify-send >/dev/null && notify-send -i web-browser "Rancher URL" "https://$RANCHER_FQDN/"
