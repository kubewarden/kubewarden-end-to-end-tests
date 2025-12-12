#!/usr/bin/env bash
set -aeEuo pipefail
trap 'echo "Error on ${BASH_SOURCE/$PWD/.}:${LINENO} $(sed -n "${LINENO} s/^\s*//p" $PWD/${BASH_SOURCE/$PWD})"' ERR

# Optional variables
K3S=${K3S:-$(k3d version -o json | jq -r '.k3s')}
CLUSTER_NAME=${CLUSTER_NAME:-k3s-default}
MASTER_COUNT=${MASTER_COUNT:-1}
WORKER_COUNT=${WORKER_COUNT:-0}
MTLS=${MTLS:-}

# Directory of the current script
BASEDIR=$(dirname "${BASH_SOURCE[0]}")

# ==================================================================================================
# Main script

. "$BASEDIR/../helpers/kubelib.sh"

# Create new cluster
if [ "${1:-}" == 'create' ]; then
    [ -v DRY ] || { precheck cluster || exit 1; }

    # Complete partial K3S version from dockerhub v1.30 -> v1.30.5-k3s1
    if [[ ! $K3S =~ ^v[0-9.]+-k3s[0-9]$ ]]; then
        K3S=$(curl -L -s "https://registry.hub.docker.com/v2/repositories/rancher/k3s/tags?page_size=20&name=$K3S" | jq -re 'first(.results[].name | select(test("^v[0-9.]+-k3s[0-9]$")))')
        echo "K3S version: $K3S"
    fi
    [ -v DRY ] && exit 0

    # Generate certificates
    if [ -n "${MTLS:-}" ]; then
        MTLS_DIR=$(realpath -s "$BASEDIR/../resources/mtls/")
        generate_certs "$MTLS_DIR" mtls.kubewarden.io
    fi

    # Detect pull-through cache for GHCR
    k3d registry list k3d-ghcr.io --no-headers 2>/dev/null && PTC_GHCR="k3d-ghcr.io"

    # /dev/mapper: https://k3d.io/v5.7.4/faq/faq/#issues-with-btrfs
    k3d cluster create "$CLUSTER_NAME" --wait \
        --config config/k3d-config-cache.yaml \
        --image "rancher/k3s:$K3S" \
        -s "$MASTER_COUNT" -a "$WORKER_COUNT" \
        -v "/dev/mapper:/dev/mapper@all:*" \
        ${PTC_GHCR:+--registry-use $PTC_GHCR} \
        ${MTLS:+--k3s-arg '--kube-apiserver-arg=admission-control-config-file=/etc/mtls/admission.yaml@server:*'} \
        ${MTLS:+--volume "$MTLS_DIR:/etc/mtls@server:*"} \
        "${@:2}"

    wait_pods -n kube-system
fi

# Delete existing cluster
if [ "${1:-}" == 'delete' ]; then
    k3d cluster delete "$CLUSTER_NAME"
fi

:
