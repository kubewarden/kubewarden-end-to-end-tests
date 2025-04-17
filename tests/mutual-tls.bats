#!/usr/bin/env bats

# mTLS has to be enabled on cluster level
# https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/

setup() {
    load ../helpers/helpers.sh
    wait_pods
}

teardown_file() {
    load ../helpers/helpers.sh
    kubectl delete pods --all
    kubectl delete ap,cap --all
    kubectl delete ps mtls-pserver --ignore-not-found
    helmer reset kubewarden-controller
}

function curlpod { kubectl exec curlpod -- curl -k --no-progress-meter $@; }

function check_service_mtls {
    local url=$1

    # Curl with a certificate works
    curlpod --cert /mtls/domain.crt --key /mtls/domain.key $url

    # Curl without a certificate fails
    run curlpod $url
    assert_failure 56
    assert_output --regexp "error.*alert certificate required"
}

@test "[Mutual TLS] Prepare resources" {
    # Create secondary Policy Server
    create_policyserver mtls-pserver

    # Set up pod with certificates for curl
    kubectl run curlpod --image=nginx:alpine
    wait_for pod curlpod
    kubectl cp resources/mtls curlpod:/mtls
}

@test "[Mutual TLS] Enable mTLS" {
    helm get values -n $NAMESPACE kubewarden-controller -o json | jq -e '.mTLS.enable == true' && skip "mTLS was enabled during installation"

    kubectl get cm -n $NAMESPACE mtlscm &>/dev/null || kubectl create cm -n $NAMESPACE mtlscm --from-file="client-ca.crt=$RESOURCES_DIR/mtls/rootCA.crt"
    helmer set kubewarden-controller --set mTLS.enable=true --set mTLS.configMapName=mtlscm
}

@test "[Mutual TLS] Check mTLS" {
    # Check mTLS is enabled in kubernetes
    kubectl get nodes -l node-role.kubernetes.io/control-plane -o yaml | grep -F "admission-control-config-file"
    # Check default PS logs
    kubectl logs -n kubewarden -l kubewarden/policy-server=default | grep -E "certs: Loaded client CA certificates client_ca_certs_added=[1-9]"

    # Check what services require certificates
    check_service_mtls https://kubewarden-controller-webhook-service.kubewarden.svc:443/validate-policies-kubewarden-io-v1-policyserver
    check_service_mtls https://policy-server-default.kubewarden.svc:8443/validate
    check_service_mtls https://policy-server-mtls-pserver.kubewarden.svc:8443/validate

    # Check protected policy still blocks requests
    apply_policy safe-labels-pods-policy.yaml
    run ! kuberun -l cost-center=lbl
}

@test "[Mutual TLS] Disable mTLS" {
    helmer set kubewarden-controller --set mTLS.enable=false

    # Talk to services without a certificate
    curlpod https://kubewarden-controller-webhook-service.kubewarden.svc:443/validate-policies-kubewarden-io-v1-policyserver
    curlpod https://policy-server-default.kubewarden.svc:8443/validate
    curlpod https://policy-server-mtls-pserver.kubewarden.svc:8443/validate

    # Check mTLS is disabled in on policy server log (grep -vz negates search)
    kubectl logs -n kubewarden -l kubewarden/policy-server=default | grep -vzE "certs: Loaded client CA certificates client_ca_certs_added=[1-9]"
}
