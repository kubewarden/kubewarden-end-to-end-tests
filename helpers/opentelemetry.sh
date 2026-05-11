#!/usr/bin/env bash
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
