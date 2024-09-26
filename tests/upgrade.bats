#!/usr/bin/env bats

setup() {
    load ../helpers/helpers.sh
    wait_pods -n kube-system
}

teardown_file() {
    load ../helpers/helpers.sh
    kubectl delete pods --all
    kubectl delete admissionpolicies,clusteradmissionpolicies --all -A
    helmer reset kubewarden-defaults
}

# helper function to allow run + pipe
function get_apiversion() {
    kubectl get $1 -o json | jq -er '.items[].apiVersion' | uniq
}

# check_apiversion admissionpolicies v1
function check_apiversion {
    run -0 get_apiversion $1
    assert_output "policies.kubewarden.io/$2"
}

@test "[CRD upgrade] Check default policies in protect mode" {
    helmer set kubewarden-defaults \
        --set recommendedPolicies.enabled=True \
        --set recommendedPolicies.defaultPolicyMode=protect

    # Wait for policies be enforced
    wait_policies PolicyUniquelyReachable

    # Check all recommended are in v1
    check_apiversion clusteradmissionpolicies v1

    # Run privileged pod (should fail)
    # kubefail_privileged run pod-privileged --image=registry.k8s.io/pause --privileged
    # Workaround - https://suse.slack.com/archives/C02DBSK7HC1/p1661518752112929
    run -1 kubectl run pod-privileged --image=registry.k8s.io/pause --privileged
}

@test "[CRD upgrade] Check old policy CRD version is translated to new" {
    yq '.apiVersion = "policies.kubewarden.io/v1alpha2"' $RESOURCES_DIR/policies/policy-pod-privileged.yaml | apply_policy
    check_apiversion admissionPolicy v1
    delete_policy policy-pod-privileged.yaml
}

@test "[CRD upgrade] Disable default policies & run privileged pod" {
    helmer set kubewarden-defaults --set recommendedPolicies.enabled=False
    kubectl run pod-privileged --image=registry.k8s.io/pause --privileged
    kubectl delete pod pod-privileged
}
