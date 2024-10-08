#!/usr/bin/env bash
set -aeEuo pipefail
# trap 'echo "Error on ${BASH_SOURCE/$PWD/.}:${LINENO} $(sed -n "${LINENO} s/^\s*//p" $PWD/${BASH_SOURCE/$PWD})"' ERR

. "$(dirname "$0")/../helpers/kubelib.sh"

# ==================================================================================================
# Global variables & Checks - Used only in install & upgrade actions

NAMESPACE=${NAMESPACE:-kubewarden}
# Kubewarden helm repository
REPO_NAME=${REPO_NAME:-kubewarden}
# Use charts from [./dirname|reponame]
CHARTS_LOCATION=${CHARTS_LOCATION:-$REPO_NAME}
# [next|prev|v1.17.0-rc2|local]
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

# Add missing "v" prefix
[[ $VERSION =~ ^[1-9] ]] && VERSION="v$VERSION"

# Check if local charts are available
[ "$VERSION" = local ] && test -d "$CHARTS_LOCATION/kubewarden-crds"

# Remove kubewarden- prefix from chart name
[ $# -gt 1 ] && set -- "$1" "${2/#kubewarden-}" "${@:3}"

# Second parameter must be short chart name or empty
[[ ${2:-} =~ ^(crds|controller|defaults)?$ ]] || { echo "Bad chart: $2"; exit 1; }

# ==================================================================================================
# Configuration of helm versions & values

print_env() {
    # Main parameters
    echo NAMESPACE=\"$NAMESPACE\"
    echo REPO_NAME=\"$REPO_NAME\"
    echo CHARTS_LOCATION=\"$CHARTS_LOCATION\"
    echo VERSION=\"$VERSION\"
    # Extra parameters
    echo CRDS_ARGS=\"$CRDS_ARGS\"
    echo CONTROLLER_ARGS=\"$CONTROLLER_ARGS\"
    echo DEFAULTS_ARGS=\"$DEFAULTS_ARGS\"
    # Version map
    for key in "${!vMap[@]}"; do
        echo vMap[$key]=\"${vMap[$key]}\"
    done
}

load_env() { source /tmp/helmer.env; }

# Parse app $VERSION into chart versions (vMap)
declare -A vMap
make_version_map() {
    # Use tempfile to avoid handling quotes in json > bash
    local tempfile=$(mktemp -p "${BATS_RUN_TMPDIR:-/tmp}" vermap-XXXXX.json)

    if [ "$VERSION" != local ]; then
        # Do single helm search query to speed up the process
        helm repo update $REPO_NAME --fail-on-repo-update-fail >/dev/null
        helm search repo --fail-on-no-result $REPO_NAME/ --versions --devel -o json \
            | jq -ec --arg appv "$VERSION" '
                def remap(items): items | unique_by(.name) | map({(.name): .version}) | add;
                unique_by(.name) as $latest |
                {
                    appv: remap(map(select(.app_version == $appv))),
                    next: remap($latest),
                    prev: remap(map(select(.app_version != $latest[0].app_version and (.app_version | contains("-rc") | not)))),
                }' > "$tempfile"
    fi

    # Load $VERSION from json into vMap array
    for chart in crds controller defaults; do
        case $VERSION in
            # Next: last version from helm search kubewarden --devel
            next)    vMap["$chart"]=$(jq -er --arg c $chart '.next["kubewarden/kubewarden-" + $c]' "$tempfile") ;;
            # Prev: previous stable version (older than next and not -rc)
            prev)    vMap["$chart"]=$(jq -er --arg c $chart '.prev["kubewarden/kubewarden-" + $c]' "$tempfile") ;;
            # App: Exact helm app version: v1.17.0-rc2
            v[1-9]*) vMap["$chart"]=$(jq -er --arg c $chart '.appv["kubewarden/kubewarden-" + $c]' "$tempfile") ;;
            # Local: directory with kw charts (kubewarden-crds, kubewarden-controller, kubewarden-defaults)
            local)   vMap["$chart"]=$(helm show chart $CHARTS_LOCATION/kubewarden-$chart | yq '.version') ;;
            *) echo "Bad VERSION: ${VERSION:-}"; exit 1;;
        esac
    done
    rm "$tempfile"

    # Save initial settings
    print_env > /tmp/helmer.env
}

# ==================================================================================================
# Install & Upgrade kubewarden (change chart version)

# Usage: helm_in kubewarden-crds [--params ..]
helm_in() { helm install --wait --wait-for-jobs --namespace $NAMESPACE "${@:2}" "$1" "$CHARTS_LOCATION/$1"; }

# Install selected $VERSION
do_install() {
    echo "Install $VERSION: ${vMap[*]}"
    # Cert-manager is required by Kubewarden <= v1.16.0 (crds < 1.9.0)
    if printf '%s\n' "${vMap[crds]}" "1.8.9" | sort -V -C; then
        helm repo add jetstack https://charts.jetstack.io --force-update
        helm upgrade -i --wait cert-manager jetstack/cert-manager -n cert-manager --create-namespace --set crds.enabled=true
    fi

    local argsvar
    for chart in ${1:-crds controller defaults}; do
        argsvar=${chart^^}_ARGS
        helm_in kubewarden-$chart --create-namespace --version "${vMap[$chart]}" ${!argsvar} "${@:2}"
    done

    if [ "${1:-defaults}" = 'defaults' ]; then
        # Initial deployment of policy-server-default is created by controller with delay
        retry "kubectl get -n $NAMESPACE deployment/policy-server-default" 2
        wait_rollout -n $NAMESPACE deployment/policy-server-default
    fi
    return 0
}

# Upgrade version and restore current values (helm recommends)
do_upgrade() {
    echo "Upgrade to $VERSION: ${vMap[*]}"

    local argsvar
    for chart in ${1:-crds controller defaults}; do
        argsvar=${chart^^}_ARGS
        # Look into --reset-then-reuse-values helm flag as replacement
        helm get values kubewarden-$chart -n $NAMESPACE -o yaml > /tmp/chart-values.yaml
        helm upgrade kubewarden-$chart -n $NAMESPACE $CHARTS_LOCATION/kubewarden-$chart --wait \
            --version "${vMap[$chart]}" --values /tmp/chart-values.yaml ${!argsvar} "${@:2}"
    done
    [ "${1:-defaults}" == 'defaults' ] && wait_rollout -n $NAMESPACE deployment/policy-server-default

    # Cert-manager is not required by Kubewarden >= v1.17.0 (crds >= 1.9.0)
    if printf '%s\n' "1.9.0" "${vMap[crds]}" | sort -V -C; then
        helm uninstall --wait cert-manager -n cert-manager --ignore-not-found
    fi
}

do_uninstall() {
    echo "Uninstall kubewarden: ${1:-charts}"
    for chart in ${1:-defaults controller crds}; do
        helm uninstall --wait --namespace $NAMESPACE kubewarden-$chart "${@:2}"
    done
}

# Modify installed chart values & keep version
do_set() {
    local chart="$1"

    local ver=$(helm get metadata kubewarden-$chart -n $NAMESPACE -o json | jq -er '.version')
    helm upgrade kubewarden-$chart $CHARTS_LOCATION/kubewarden-$chart -n $NAMESPACE --wait --wait-for-jobs \
         --version "$ver" --reuse-values "${@:2}"

    [ "$1" = 'defaults' ] && wait_rollout -n $NAMESPACE deployment/policy-server-default
    return 0
}

do_reset() {
    local chart="$1"
    local argsvar=${chart^^}_ARGS

    local ver=$(helm get metadata kubewarden-$chart -n $NAMESPACE -o json | jq -er '.version')
    helm upgrade kubewarden-$chart $CHARTS_LOCATION/kubewarden-$chart -n $NAMESPACE --wait --wait-for-jobs \
         --version "$ver" --reset-values ${!argsvar} "${@:2}"

    # Wait for pods to be ready
    [ "$1" = 'defaults' ] && wait_rollout -n $NAMESPACE deployment/policy-server-default
    return 0
}

case $1 in
    in|install|up|upgrade)
        make_version_map;;&
    reinstall|uninstall|set|reset)
        load_env;;&

    in|install) do_install "${@:2}";;
    up|upgrade) do_upgrade "${@:2}";;
    reinstall)  do_install "${@:2}";;
    uninstall)  do_uninstall "${@:2}";;
    set)        do_set $2 "${@:3}";;
    reset)      do_reset $2 "${@:3}";;
    debug)
        echo "### Helmer env:"
        cat /tmp/helmer.env
        echo "### Helm ls:"
        helm ls -n $NAMESPACE -o json | jq ".[].chart"
        echo "### Current charts values:"
        for chart in crds controller defaults; do
            helm get values kubewarden-$chart -n $NAMESPACE
        done
        ;;
    *)
        echo "Bad command: $1"; exit 1;;
esac
