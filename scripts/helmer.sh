#!/usr/bin/env bash
set -aeEuo pipefail
trap 'echo "Error on ${BASH_SOURCE/$PWD/.}:${LINENO} $(sed -n "${LINENO} s/^\s*//p" $PWD/${BASH_SOURCE/$PWD})"' ERR

# ==================================================================================================
# Helmer - Management script for kubewarden charts
#
# - Keeps initial installation parameters so we can run follow-up tests with the same setup
# - Provides consistent way to modify helm charts without upgrading chart version
# - Introduce helpers to install kubewarden stack based on app version
# - Allows to test latest images - they are not modified from test files
# - Used by makefile targets to install & upgrade kubewarden

# Usage:
# VERSION=1.16.0 CONTROLLER_ARGS="--set image.tag=latest" ./helmer install
# CHARTS_LOCATION=./charts DEFAULTS_ARGS="--set recommendedPolicies.enabled=true" ./helmer install

# Keep original values: VERSION, CHARTS_LOCATION, CONTROLLER_ARGS
# ./helmer set controller --set telemetry.metrics.enabled=False

# Reinstall with initial values: VERSION, CHARTS_LOCATION, CONTROLLER_ARGS
# helm uninstall kubewarden-defaults -n kubewarden
# ./helmer reinstall defaults

# Reset helm chart values to initial state
# ./helmer reset controller

# ==================================================================================================
# Global variables & Checks - Used only in install & upgrade actions

# Find if Rancher is installed
RANCHER=${RANCHER:-$(helm status -n cattle-system rancher &>/dev/null && echo 1 || echo "")}

NAMESPACE=${NAMESPACE:-kubewarden}
# Kubewarden helm repository
REPO_NAME=${REPO_NAME:-kubewarden}
# Use charts from [./dirname|reponame]
CHARTS_LOCATION=${CHARTS_LOCATION:-$REPO_NAME}

# [next|prev|v1.17.0-rc2|local] - defaults to local if CHARTS_LOCATION is path, otherwise next
# - next: last version from helm search kubewarden --devel
# - prev: previous stable version (older than next and not -rc)
# - v\d*: Helm app version: v1.17.0-rc2, 1.17 (autocompleted)
# - local: directory with kw charts (kubewarden-crds, kubewarden-controller, kubewarden-defaults)
VERSION=${VERSION:-$( [[ "$CHARTS_LOCATION" == */* ]] && echo "local" || echo "next" )}

# Extra parameters for helm install
CRDS_ARGS="${CRDS_ARGS:-}"
CONTROLLER_ARGS="${CONTROLLER_ARGS:-}"
DEFAULTS_ARGS="${DEFAULTS_ARGS:-}"
# Use latest tag for main images
if [ -n "${LATEST:-}" ]; then
    DEFAULTS_ARGS="--set policyServer.image.tag=latest $DEFAULTS_ARGS"
    CONTROLLER_ARGS="--set image.tag=latest --set auditScanner.image.tag=latest $CONTROLLER_ARGS"
fi
# Use mTLS parameters
if [ -n "${MTLS:-}" ]; then
    CONTROLLER_ARGS="--set mTLS.enable=true --set mTLS.configMapName=mtlscm $CONTROLLER_ARGS"
fi

# Prepend "v" and append .0 to partial versions
[[ $VERSION =~ ^[1-9] ]] && VERSION="v$VERSION"
[[ $VERSION =~ ^v[1-9]+\.[0-9]+$ ]] && VERSION="${VERSION}.0"
# Check if local charts directory exists
[ "$VERSION" = local ] && test -d "$CHARTS_LOCATION/kubewarden-crds"
# Check if version is valid
[[ $VERSION =~ ^(local|next|prev|v[1-9].*)$ ]] || { echo "Bad VERSION: $VERSION"; exit 1; }

# Remove kubewarden- prefix from chart name
[ $# -gt 1 ] && set -- "$1" "${2/#kubewarden-}" "${@:3}"

# Second parameter must be short chart name or empty
[[ ${2:-} =~ ^(crds|controller|defaults)?$ ]] || { echo "Bad chart: $2"; exit 1; }

# Directory of the current script
BASEDIR=$(dirname "${BASH_SOURCE[0]}")

# ==================================================================================================
# Configuration of helm versions & values

. "$BASEDIR/../helpers/kubelib.sh"

print_env() {
    # Main parameters
    echo NAMESPACE=\""$NAMESPACE"\"
    echo REPO_NAME=\""$REPO_NAME"\"
    echo CHARTS_LOCATION=\""$CHARTS_LOCATION"\"
    echo VERSION=\""$VERSION"\"
    # Extra parameters
    echo CRDS_ARGS=\""$CRDS_ARGS"\"
    echo CONTROLLER_ARGS=\""$CONTROLLER_ARGS"\"
    echo DEFAULTS_ARGS=\""$DEFAULTS_ARGS"\"
    # Version map
    for key in "${!vMap[@]}"; do
        echo vMap["$key"]=\""${vMap[$key]}"\"
    done
}

load_env() { source /tmp/helmer.env; }

# Parse app $VERSION into chart versions (vMap)
declare -A vMap
make_version_map() {
    # Use tempfile to avoid handling quotes in json > bash
    local tempfile
    tempfile=$(mktemp -p "${BATS_RUN_TMPDIR:-/tmp}" vermap-XXXXX.json)

    if [ "$VERSION" != local ]; then
        # Do single helm search query to speed up the process
        helm repo update "$REPO_NAME" --fail-on-repo-update-fail >/dev/null
        helm search repo --fail-on-no-result "$REPO_NAME/" --versions --devel -o json \
            | jq -ec --arg v "$VERSION" '
                def remap(items): items | unique_by(.name) | map({(.name): .version, app_version: .app_version}) | add;
                unique_by(.name) as $latest |
                {
                    ($v): remap(map(select(.app_version == $v))),
                    next: remap($latest),
                    prev: remap(map(select(.app_version != $latest[0].app_version and (.app_version | test("-rc|-beta|-alpha") | not)))),
                }' > "$tempfile"
    fi

    # Load app & charts from json into vMap array
    vMap["app"]=$( test "$VERSION" = "local" \
        && helm show chart "$CHARTS_LOCATION/kubewarden-crds" | yq '.appVersion' \
        || jq -er --arg k "$VERSION" '.[$k]["app_version"]' "$tempfile" )

    for chart in crds controller defaults; do
        vMap["$chart"]=$( test "$VERSION" = "local" \
            && helm show chart "$CHARTS_LOCATION/kubewarden-$chart" | yq '.version' \
            || jq -er --arg k "$VERSION" --arg c $chart '.[$k]["kubewarden/kubewarden-" + $c]' "$tempfile" )
    done
    rm "$tempfile"

    # Save initial settings
    print_env > /tmp/helmer.env
}

print_version_map() {
    local out
    for k in app crds controller defaults; do
        out+="$k:${vMap[$k]} "
    done
    echo -n "${out% }" # Remove trailing space
}

# ==================================================================================================
# Install & Upgrade kubewarden (change chart version)

# Usage: helm_up kubewarden-crds [--params ..]
helm_up() {
    echo helm_up ... -n "$NAMESPACE" "${@:2}" "$1" "$CHARTS_LOCATION/$1"
    helm upgrade -i --wait --wait-for-jobs -n "$NAMESPACE" "${@:2}" "$1" "$CHARTS_LOCATION/$1"
}

# Required configuration before install / upgrade
setup_requirements() {
    # Create k3d cluster if it doesn't exist
    kubectl cluster-info &>/dev/null || "$BASEDIR"/cluster_k3d.sh create

    # No namespace = installation
    if ! kubectl get ns "$NAMESPACE" &>/dev/null; then
        kubectl create ns "$NAMESPACE"
        # Enforce PSA restricted profile - https://github.com/kubewarden/helm-charts/pull/648
        if is_version ">=1.23" "${vMap[app]}"; then
            kubectl label ns "$NAMESPACE" kubewarden.io/psa-restricted=restricted
        fi
    fi

    # Helm charts require mTLS configmap
    if [ -n "${MTLS:-}" ]; then
        kubectl get cm -n "$NAMESPACE" mtlscm &>/dev/null || kubectl create cm -n "$NAMESPACE" mtlscm --from-file=client-ca.crt="$BASEDIR/../resources/mtls/rootCA.crt"
    fi
}

# Install selected $VERSION
do_install() {
    echo "Install $VERSION: ($(print_version_map))"

    local argsvar
    for chart in ${1:-crds controller defaults}; do
        argsvar=${chart^^}_ARGS
        # shellcheck disable=SC2086
        helm_up "kubewarden-$chart" --version "${vMap[$chart]}" ${!argsvar} "${@:2}"
    done

    if [ "${1:-defaults}" = 'defaults' ]; then
        # Initial deployment of policy-server-default is created by controller with delay
        retry "kubectl get -n $NAMESPACE deployment/policy-server-default" 5
        wait_rollout deployment/policy-server-default
    fi

    return 0
}

# Install on Rancher
do_install_on_rancher() {
    echo "Install $VERSION: ($(print_version_map))"

    local datadir rancher_url rancher_token
    datadir=$BASEDIR/../resources/rancher
    rancher_url=https://$(helm get values -n cattle-system rancher -o json | jq -re '.hostname')
    rancher_token=$(curl -k --fail-with-body --no-progress-meter --json '{"username":"admin","password":"sa"}' "$rancher_url/v3-public/localProviders/local?action=login" | jq -re '.token')

    appinstall() {
        local json="$1"
        local repo="$2"
        local helmop
        # Trigger helm operation to install app from repository
        helmop=$(curl -k --fail-with-body --no-progress-meter -u "$rancher_token" -X POST --json "$json" "$rancher_url/v1/catalog.cattle.io.clusterrepos/${repo}?action=install" | jq -re '.operationName')
        retry "kubectl get pod -n cattle-system $helmop | grep -qEw 'Completed|Error'" 20 6
        kubectl logs -n cattle-system "$helmop" -c helm | tee /dev/tty | grep -qE "^SUCCESS: helm.*/kubewarden-"
    }

    # Merge values from static json and --set parameters
    merge_values() {
        local result key value
        result=$(cat)
        for param in $(grep -oE -- '--set [^=]+=[^[:space:]]+' <<<"$*" ||:); do
            [[ $param == --set ]] && continue

            # Convert helm key (a.b.c) to jsonpath ["charts", 0, "values", "a", "b", "c"]
            key=${param%%=*}
            key=$(jq -n --arg k "$key" '["charts", 0, "values"] + ($k | split("."))')
            # Escape string value for jq
            value=${param#*=}
            [[ $value =~ ^(true|false|[0-9]+(\.[0-9]+)?)$ ]] || value=$(jq -n --arg v "$value" '$v')

            # Update the value in the result json
            result=$(jq -c --argjson k "$key" --argjson v "$value" 'setpath($k; $v)' <<<"$result")
        done
        echo "$result"
    }

    # Add extension & kubewarden repositories
    local extrepo extver
    curl -k --fail-with-body --no-progress-meter "$rancher_url/rancherversion" | jq -re '.RancherPrime == "true"' && extrepo=rancher-ui-plugins || extrepo=kubewarden-extension-github
    for i in $extrepo kubewarden-charts; do
        kubectl get clusterrepos "$i" &>/dev/null || kubectl apply -f "$datadir/repo-$i.yaml"
        retry "kubectl get clusterrepos $i -o json | jq -e '.status.downloadTime' > /dev/null" 5 3
    done

    # Install UI extension
    extver=$(curl -k --fail-with-body --no-progress-meter -u "$rancher_token" "$rancher_url/v1/catalog.cattle.io.clusterrepos/$extrepo?link=index" | jq -er '.entries.kubewarden[0].version')
    jq -ce --arg v "$extver" '.charts[0].version = $v' "$datadir/curl-data-extension.json" | appinstall @- "$extrepo"

    # Install Kubewarden charts
    local argsvar
    for chart in ${1:-crds controller defaults}; do
        argsvar=${chart^^}_ARGS
        # Update app version in json and install
        jq -ce --arg v "${vMap[$chart]}" '.charts[0].version = $v' "$datadir/curl-data-$chart.json" \
            | merge_values "${!argsvar}" "${@:2}" \
            | appinstall @- "kubewarden-charts"
        [ "$chart" == 'controller' ] && wait_rollout deployment/rancher-kubewarden-controller
        [ "$chart" == 'defaults' ] && wait_rollout deployment/policy-server-default
    done

    return 0
}

# Upgrade version and restore current values (helm recommends)
do_upgrade() {
    echo "Upgrade to $VERSION:($(print_version_map))"

    local argsvar
    for chart in ${1:-crds controller defaults}; do
        argsvar=${chart^^}_ARGS
        # Look into --reset-then-reuse-values helm flag as replacement
        helm get values "kubewarden-$chart" -n "$NAMESPACE" -o yaml > /tmp/chart-values.yaml
        # shellcheck disable=SC2086
        helm_up "kubewarden-$chart" --version "${vMap[$chart]}" --values /tmp/chart-values.yaml ${!argsvar} "${@:2}"

        if [ "$chart" = 'controller' ]; then
            [[ "${vMap[$chart]}" == 4.1* ]] && continue # Url renamed to Module in PS ConfigMap
            [[ "${vMap[$chart]}" == 5.0* ]] && continue # Probe port change from https to http
            sleep 20 # Wait for reconciliation
            wait_rollout deployment/policy-server-default
        fi
    done
    [ "${1:-defaults}" == 'defaults' ] && wait_rollout deployment/policy-server-default

    return 0
}

do_uninstall() {
    echo "Uninstall kubewarden: ${1:-charts}"
    for chart in ${1:-defaults controller crds}; do
        helm uninstall --wait --namespace "$NAMESPACE" "kubewarden-$chart" "${@:2}"
    done
}

# Modify installed chart values & keep version
do_set() {
    local chart="$1"

    local ver
    ver=$(helm get metadata "kubewarden-$chart" -n "$NAMESPACE" -o json | jq -er '.version')
    helm_up "kubewarden-$chart" --version "$ver" --reuse-values "${@:2}"

    [[ "$1" == 'controller' ]] && sleep 20 # Wait for reconciliation
    [[ "$1" =~ (controller|defaults) ]] && wait_rollout deployment/policy-server-default
    return 0
}

do_reset() {
    local chart="$1"
    local argsvar=${chart^^}_ARGS

    local ver
    ver=$(helm get metadata "kubewarden-$chart" -n "$NAMESPACE" -o json | jq -er '.version')
    # shellcheck disable=SC2086
    helm_up "kubewarden-$chart" --version "$ver" --reset-values ${!argsvar} "${@:2}"

    # Wait for pods to be ready
    [ "$1" = 'defaults' ] && wait_rollout deployment/policy-server-default
    return 0
}

# ==================================================================================================
# Main script

case $1 in
    # Build version map of charts
    in|install|up|upgrade|versions)
        make_version_map;;&
    reinstall|uninstall|set|reset)
        load_env;;&

    # Handle kubewarden requirements
    in|install|up|upgrade) [ -v DRY ] || setup_requirements;;&

    # Call action function
    versions)
        echo "Version map: ($(print_version_map))"; exit 0;;
    in|install)
        [ -v DRY ] && { echo "Install $VERSION: ($(print_version_map))"; exit 0; }
        precheck kubewarden || exit 1
        do_install${RANCHER:+_on_rancher} "${@:2}";;
    up|upgrade) do_upgrade "${@:2}";;
    reinstall)  do_install "${@:2}";;
    uninstall)  do_uninstall "${@:2}";;
    set)        do_set "$2" "${@:3}";;
    reset)      do_reset "$2" "${@:3}";;
    debug)
        echo "### Helmer env:"
        cat /tmp/helmer.env
        echo "### Helm ls:"
        helm ls -n "$NAMESPACE" -o json | jq ".[].chart"
        echo "### Current charts values:"
        for chart in crds controller defaults; do
            helm get values ${RANCHER:+rancher-}kubewarden-$chart -n "$NAMESPACE"
        done
        ;;
    *)
        echo "Bad command: $1"; exit 1;;
esac
