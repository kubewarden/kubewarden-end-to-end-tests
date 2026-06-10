#!/usr/bin/env bash
set -aeEuo pipefail
# Shared OpenTelemetry-related BATS helpers.
# Source via: load "../helpers/opentelemetry.sh"

# get_metrics <service-name> [port]
# Curls the Prometheus metrics endpoint of the given service.
# Port defaults to 8080 (OTel sidecar/collector default).
function get_metrics {
    local svc=$1
    local port=${2:-8080}
    is_appco && svc=${1/#kubewarden-controller/ssac-&}

    kubectl delete pod curlpod --ignore-not-found
    kubectl run curlpod -t -i --rm --image curlimages/curl:8.17.0 --restart=Never -- \
        --silent $svc.$NAMESPACE.svc.cluster.local:$port/metrics
}
export -f get_metrics

# assert_deployment_hostnetwork <label-selector> <true|false>
# Verifies that the deployment matching the selector has the expected
# hostNetwork setting in its pod template.
assert_deployment_hostnetwork() {
    local label_selector="$1" expected="$2"
    local hostnet

    hostnet=$(kubectl get deployment -n "$NAMESPACE" -l "$label_selector" \
        -o jsonpath='{.items[0].spec.template.spec.hostNetwork}')

    [[ "${expected:-false}" == "${hostnet:-false}" ]]
}