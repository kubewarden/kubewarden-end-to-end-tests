#!/usr/bin/env bash
set -aeEuo pipefail

# ==================================================================================================
# General helpers

log  () { printf -- "$(date +%R) \e[${1}m${*:2}\e[0m\n"; }
step () { log 32 "${*}" $(basename "${BASH_SOURCE[1]/${BASH_SOURCE}}" | sed 's/.\+/[&]/'); } # print test module
info () { log 0  "  ${*}"; }
warn () { log 33 "  ${*}"; }
error() { log 31 "  ${*}"; }

# ==================================================================================================
# Kubernetes helpers

yq() { command yq -e "$@"; }
jq() { command jq -e "$@"; }

# Export for retry function (subshell)
export -f yq jq

function retry() {
    local cmd="$1"
    local tries="${2:-20}"
    local delay="${3:-15}"
    local i status

    for ((i=1; i<=tries; i++)); do
        timeout $delay bash -c "$cmd" && break || status=$?
        if [[ $i -lt $tries ]]; then
            echo "RETRY #$i: $cmd"
            [[ $status -ne 124 ]] && sleep $delay
        else
            echo "Godot ($status): $cmd"; false
        fi
    done
}

# Safe version of waiting for pods. Looks in kube-system ns by default
# Handles kube-api disconnects during upgrade
function wait_pods() {
    local i output
    for i in {1..30}; do
        output=$(kubectl get pods --no-headers -o wide ${@:--n kubewarden} | grep -vw Completed || echo 'Fail')
        grep -vE '([0-9]+)/\1 +Running' <<< $output || break
        [ $i -ne 30 ] && sleep 15 || { echo "Godot: pods not running"; false; }
    done
}

# Safe version of waiting for nodes
# Handles kube-api disconnects during upgrade
function wait_nodes() {
    local i output
    for i in {1..20}; do
        output=$(kubectl get nodes --no-headers ${@:-} || echo 'Fail')
        grep -vE '\bReady\b' <<< $output || break
        [ $i -ne 20 ] && sleep 30 || { echo "Godot: nodes not running"; false; }
    done
}

function wait_for    () { kubectl wait --timeout=5m "$@"; }
function wait_rollout() { kubectl rollout status --timeout=5m "$@"; }

# Wait for cluster to come up after reboot
function wait_cluster() {
    retry "kubectl cluster-info" 20 30
    wait_nodes
    wait_pods
}


# ==================================================================================================
# Version helpers

eq() { [[ "$1" == "$2"* ]]; } # Check if $1 starts with $2
le() { printf '%s\n' "$1" "$2" | sed '/-/!{s/$/_/}' | sort -V -C; } # sed _ to sort RC < Release
ge() { printf '%s\n' "$1" "$2" | sed '/-/!{s/$/_/}' | sort -V -C -r; }
gt() { ! le "$1" "$2"; }
lt() { ! ge "$1" "$2"; }

# Check if current version satisfies query (semver.satifies)
# $1: version query (e.g., ">=1.17", "<1.17.0", "=1.17.0-rc2")
# $2: current version (e.g., "1.17.0-rc1")
is_version() {
    local qsign="${1%%[0-9]*}"  # Extract sign (e.g., ">=", "=", etc.)
    local qver="${1#"$qsign"}"  # Remove sign from version (e.g., "1.17.0")
    local current="${2/#v}"     # Current version, strip the leading 'v'

    # Append ".0" to partial qver (or 1.17.0 > 1.17)
    [[ "$qver" =~ ^[0-9]+\.[0-9]+$ ]] && qver="${qver}.0"
    # Strip -rc from current version if not querying RC (or 1.17.0-rc2 < 1.17.0)
    [[ "$qver" != *-rc* ]] && current="${current%-rc*}"

    case "$qsign" in
        *">"*) gt "$current" "$qver" && return 0 ;;&
        *"<"*) lt "$current" "$qver" && return 0 ;;&
        *"="*) eq "$current" "$qver" && return 0 ;;&
    esac
    return 1
}

# Query against installed kubewarden app version
kw_version() { is_version "$1" "$(helm ls -n $NAMESPACE -f kubewarden-crds -o json | jq -r '.[0].app_version')"; }
