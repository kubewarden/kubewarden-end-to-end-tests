#!/usr/bin/env bats
#
# This test requires signed package. To sign follow this steps & modify configmaps accordingly
# $ kwctl pull registry://ghcr.io/kubewarden/policies/pod-privileged:v0.2.1
# $ kwctl push
#    ~/.cache/kubewarden/store/registry/ghcr.io/kubewarden/policies/pod-privileged:v0.2.1 \
#    ghcr.io/kubewarden/tests/pod-privileged:v0.2.1
# $ COSIGN_PASSWORD=kubewarden cosign generate-key-pair
# $ COSIGN_PASSWORD=kubewarden cosign sign --key cosign.key -a env=prod ghcr.io/kubewarden/tests/pod-privileged:v0.2.1


CONFIGMAP_NAME="ssc-verification-config"

setup() {
    setup_helper
}
teardown_file() {
    teardown_helper
    helmer reset kubewarden-defaults
    kubectl delete configmap -n $NAMESPACE $CONFIGMAP_NAME --ignore-not-found
}

function create_configmap {
    kubectl -n $NAMESPACE delete configmap $CONFIGMAP_NAME --ignore-not-found
    kubectl -n $NAMESPACE create configmap $CONFIGMAP_NAME --from-file=verification-config=$1
}

function get_policy_server_status {
    # get latest policy-server pod
    local podname=$(kubectl get pods -n kubewarden --selector=app.kubernetes.io/instance=policy-server-default --sort-by=.metadata.creationTimestamp -o jsonpath="{.items[-1].metadata.name}")
    # fill output with logs, 10s timeout because pod restart cleans up
    kubectl logs -n $NAMESPACE $podname --request-timeout=10s -f

    # fill exit code with pod status
    kubectl get pod -n $NAMESPACE $podname -o json | jq -e '.status.containerStatuses[0].ready == true'
}

# Configure kubewarden to check policy signatures
# https://docs.kubewarden.io/distributing-policies/secure-supply-chain#configuring-the-policy-server-to-check-policy-signatures
@test "[Secure Supply Chain tests] Enable" {
    # policyserver needs configmap to start in verification mode
    create_configmap <(kwctl scaffold verification-config)
    helmer set kubewarden-defaults --set policyServer.verificationConfig=$CONFIGMAP_NAME
    kubectl get policyserver default -o json | jq -e --arg cmname $CONFIGMAP_NAME '.spec.verificationConfig == $cmname'
}

@test "[Secure Supply Chain tests] Trusted policy should not block policy server" {
    create_configmap $RESOURCES_DIR/secure-supply-chain-cm.yaml

    # Policy Server should start fine
    apply_policy policy-pod-privileged.yaml

    # Check logs of last policyserver pod
    run -0 get_policy_server_status
    assert_output -p 'verifying policy authenticity and integrity using sigstore'
    assert_output -p 'Local file checksum verification passed'

    delete_policy policy-pod-privileged.yaml
}

@test "[Secure Supply Chain tests] Untrusted policy should block policy server to run" {
    create_configmap $RESOURCES_DIR/secure-supply-chain-cm-restricted.yaml

    # Policy Server startup should fail
    apply_policy --no-wait policy-pod-privileged.yaml
    run kubectl -n $NAMESPACE rollout status --timeout=1m "deployment/policy-server-default"
    assert_failure 1

    # Check logs of last policyserver pod
    run -1 get_policy_server_status
    assert_output -p 'Annotation not satisfied'
    assert_output -p 'policy cannot be verified'

    delete_policy policy-pod-privileged.yaml
}
