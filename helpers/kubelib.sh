#!/usr/bin/env bash
set -aeEuo pipefail

# ==================================================================================================
# General helpers

log  () { printf -- "$(date +%R) \e[${1}m${*:2}\e[0m\n"; }
step () { log 32 "${*}" $(basename "${BASH_SOURCE[1]/${BASH_SOURCE}}" | sed 's/.\+/[&]/'); } # print test module
info () { log 0  "  ${*}"; }
warn () { log 33 "  ${*}"; }
error() { log 31 "  ${*}"; }

# Check github truthy | falsy variables
gh_true() { ! is_false "$1"; }
gh_false() { [[ "${!1:-}" =~ ^(false|0|-0|null)$ ]]; }

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

# Wait for Ready condition by default, could be overridden with --for=condition=...
function wait_for    () { kubectl wait --timeout=5m --for=condition=Ready "$@"; }
# Wait for terminating pods after rollout
function wait_rollout() { kubectl rollout status --timeout=5m "$@"; wait_pods; }

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

# SemVer: Append _ to stable versions to sort RC < Release
semsort() { sed -E '/[0-9]-[a-z]/! s/([0-9])( |$)/\1_\2/g' | sort -b -V "${@:-}" | sed -E 's/([0-9])_( |$)/\1\2/g'; }

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

# ==================================================================================================
# Others

# https://www.baeldung.com/openssl-self-signed-cert
function generate_certs {
    local path=${1:-}
    local fqdn=${2:-cert.kubewarden.io}

    mkdir -p $path && cd $path
    # Create CA
    openssl req -nodes -batch -x509 -sha256 -days 365 -newkey rsa:2048 -keyout rootCA.key -out rootCA.crt
    # Create CSR
    openssl req -nodes -batch -newkey rsa:2048 -keyout domain.key -out domain.csr \
        -addext "subjectAltName = DNS:$fqdn"
    # Create CRT
    openssl x509 -req -CA rootCA.crt -CAkey rootCA.key -in domain.csr -out domain.crt -days 365 -CAcreateserial \
        -extfile <(echo "subjectAltName=DNS:$fqdn")
    # Print CRT
    # openssl x509 -text -noout -in domain.crt
    cd -
}

# Run command and delete pod afterwards. Use busybox by default.
# When both kubectl args & command are used: -- separator is required.
# kuberun [kubectl args] -- [command [args]]
function kuberun {
    # No kubectl args: add -- separator
    [ "${1:0:1}" != "-" ] && set -- -- "$@"
    # No command (-- is missing): use -- true as default
    [[ " $* " != *" -- "* ]] && set -- "$@" -- true
    # Set command defaults
    [[ "$*" =~ "-- wget" ]] && set -- "${@/-- wget/-- wget --quiet --no-check-certificates}"
    [[ "$*" =~ "-- curl" ]] && set -- "${@/-- curl/-- curl -k --no-progress-meter}"

    kubectl run "pod-$(date +%s)" --image=busybox --restart=Never --rm -it -q --command "$@"
}
export -f kuberun
