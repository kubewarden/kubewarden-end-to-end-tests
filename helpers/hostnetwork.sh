#!/usr/bin/env bash
set -aeEuo pipefail
# Shared helpers for hostNetwork-related BATS tests.
# Source via: load "../helpers/hostnetwork.sh"

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

# create_policyserver_with_ports <name> <webhookPort> <readinessProbePort>
# Creates a PolicyServer CR with explicit custom ports, detecting the
# correct image from the current Helm release.
#
# webhookPort and readinessProbePort are pod-side ports: they set env vars
# (KUBEWARDEN_PORT and KUBEWARDEN_READINESS_PROBE_PORT) that determine which
# host port the PolicyServer container actually binds. These must be unique
# across all PolicyServers on the same host when hostNetwork is enabled.
create_policyserver_with_ports() {
    local name="$1" webhook_port="$2" readiness_port="$3"
    local image

    if is_appco; then
        image="dp.apps.rancher.io/containers/kubewarden-policy-server:$(helm get values -a -n kubewarden ssac -o json | jq -er '."kubewarden-defaults".policyServer.image.tag')"
    else
        image="ghcr.io/$(helm get values -a kubewarden-defaults -n kubewarden -o json | jq -er '.policyServer.image | .repository + ":" + .tag')"
    fi

    kubectl apply -f - <<EOF
apiVersion: policies.kubewarden.io/v1
kind: PolicyServer
metadata:
  name: $name
spec:
  image: $image
  replicas: 1
  webhookPort: $webhook_port
  readinessProbePort: $readiness_port
EOF

    wait_policyserver "$name"
}
