#!/usr/bin/env bats

setup() {
    load ../helpers/helpers.sh
    wait_pods
}

setup_file() {
    load ../helpers/helpers.sh
    kubectl get cm -n $NAMESPACE mtlscm &>/dev/null || kubectl create cm -n $NAMESPACE mtlscm --from-file="client-ca.crt=$RESOURCES_DIR/mtls/rootCA.crt"
}

teardown_file() {
    load ../helpers/helpers.sh
    helmer reset kubewarden-defaults
    helmer reset kubewarden-controller
}

# Skip tests if MTLS is disabled
[[ "${MTLS:-}" =~ ^(false|0)?$ ]] && skip "Mutual TLS is disabled"

@test "[Mutual TLS] Enable mTLS" {
    helmer set kubewarden-controller --set mTLS.enable=true --set mTLS.configMapName=mtlscm

    kubectl get nodes -l node-role.kubernetes.io/control-plane -o yaml | grep -F "admission-control-config-file"
    kubectl logs -n kubewarden -l kubewarden/policy-server=default | grep -E "certs: Loaded client CA certificates client_ca_certs_added=[1-9]"

    # Run more checks? What to check for?
    # How to check I can't talk to webhook now?
    # helmer set kubewarden-defaults --set recommendedPolicies.enabled=True
}

@test "[Mutual TLS] Disable mTLS" {
    helmer set kubewarden-controller --set mTLS.enable=false

    ! kubectl get nodes -l node-role.kubernetes.io/control-plane -o yaml | grep -F "admission-control-config-file"
    ! kubectl logs -n kubewarden -l kubewarden/policy-server=default | grep -E "certs: Loaded client CA certificates client_ca_certs_added=[1-9]"
}
