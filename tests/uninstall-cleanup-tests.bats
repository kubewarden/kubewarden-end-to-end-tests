#!/usr/bin/env bats

# Tests for the controller --cleanup uninstall behaviour.
#
# This file is excluded from the default `make tests` run because it uninstalls
# and reinstalls the whole Kubewarden stack. Run explicitly with: 
# make uninstall-cleanup-tests.bats

setup() {
    setup_helper
}

teardown_file() {
    teardown_helper
}

# has_kw_finalizer <kind> <name>
# Returns 0 (success) if the object carries the kubewarden.io/finalizer.
has_kw_finalizer() {
    local kind="$1"
    local name="$2"
    kubectl get "$kind" "$name" -o json \
        | jq -e '.metadata.finalizers // [] | index("kubewarden.io/finalizer") != null'
}

# assert_no_kw_finalizer <kind> <name>
# Fails the test if the kubewarden.io/finalizer is still present.
assert_no_kw_finalizer() {
    local kind="$1"
    local name="$2"
    run has_kw_finalizer "$kind" "$name"
    assert_failure
}

# assert_no_kw_webhooks
# Fails the test if any webhook configuration labeled
# app.kubernetes.io/part-of=kubewarden still exists.
assert_no_kw_webhooks() {
    kubectl get validatingwebhookconfigurations \
        -l app.kubernetes.io/part-of=kubewarden -o json \
        | jq -e '.items | length == 0'

    kubectl get mutatingwebhookconfigurations \
        -l app.kubernetes.io/part-of=kubewarden -o json \
        | jq -e '.items | length == 0'
}

# Create user-defined resources that must survive the uninstall.
# Also creates a throwaway PolicyServer used only to verify plain-kubectl
# deletion works without a running controller.
@test "$(tfile) Setup user-defined PolicyServer and policy" {
    create_policyserver e2e-cleanup-user

    ps=e2e-cleanup-user yq '.spec.policyServer = env(ps)' \
        "$RESOURCES_DIR/policies/privileged-pod-policy.yaml" \
        | kubectl apply -f -
    wait_for --for=condition=PolicyActive clusteradmissionpolicies --all -A
    wait_for --for=condition=PolicyUniquelyReachable clusteradmissionpolicies --all -A

    create_policyserver e2e-cleanup-throwaway

    has_kw_finalizer policyserver e2e-cleanup-user
    has_kw_finalizer policyserver e2e-cleanup-throwaway
}

# Helm uninstall should delete the controller, all policy-server backing
# resources, and every Kubewarden webhook configuration.
@test "$(tfile) Uninstall removes controller, policy-servers and webhooks" {
    helmer uninstall

    
    kubectl get deployments -n "$NAMESPACE" \
        -l app.kubernetes.io/component=controller -o json \
        | jq -e '.items | length == 0'

    kubectl get deployments -n "$NAMESPACE" \
        -l app.kubernetes.io/component=policy-server -o json \
        | jq -e '.items | length == 0'

    assert_no_kw_webhooks

    run kubectl get policyserver default
    assert_failure
    kubectl get clusteradmissionpolicies \
        -l kubewarden.io/managed-by=kubewarden-controller-defaults -o json \
        | jq -e '.items | length == 0'

    # Wait for policy-server pods to be fully gone. `helm uninstall --wait`
    # does not track the CR-owned policy-server pods, so they can linger in
    # Terminating state after the release is removed. Subsequent tests must not
    # start while Terminating pods are present or setup_helper's wait_pods will
    # fail. This also directly verifies that the cleanup tore down the running
    # policy-servers (PR #1879 guarantee). 
    retry "! kubectl get pods -n $NAMESPACE -l app.kubernetes.io/component=policy-server -o name | grep -q ." 18 10
}

# CRDs and user custom resources must be preserved, but with their Kubewarden
# finalizers stripped so they are no longer blocked by a controller that is no
# longer running.
# bats test_tags=setup:--no-wait
@test "$(tfile) Uninstall keeps CRDs and user custom resources without finalizers" {
    # Kubewarden CRDs are still registered
    run kubectl get crd policyservers.policies.kubewarden.io
    assert_success
    run kubectl get crd clusteradmissionpolicies.policies.kubewarden.io
    assert_success
    run kubectl get crd admissionpolicies.policies.kubewarden.io
    assert_success
    run kubectl get crd clusteradmissionpolicygroups.policies.kubewarden.io
    assert_success
    run kubectl get crd admissionpolicygroups.policies.kubewarden.io
    assert_success

    kubectl get policyserver e2e-cleanup-user
    kubectl get policyserver e2e-cleanup-throwaway
    kubectl get clusteradmissionpolicy privileged-pods

    assert_no_kw_finalizer policyserver e2e-cleanup-user
    assert_no_kw_finalizer policyserver e2e-cleanup-throwaway
    assert_no_kw_finalizer clusteradmissionpolicy privileged-pods
}

# A finalizer-stripped user CR can be deleted with plain kubectl,
# without a running controller to honor its (now-absent) finalizer.
# bats test_tags=setup:--no-wait
@test "$(tfile) Finalizer-stripped user resource can be deleted with plain kubectl" {
    kubectl delete policyserver e2e-cleanup-throwaway --wait --timeout=60s

    run kubectl get policyserver e2e-cleanup-throwaway
    assert_failure
}

# After reinstall, the controller re-adopts the kept user PolicyServer and
# its policy, re-adds the kubewarden.io/finalizer, and the policy becomes
# functionally active again. 
# bats test_tags=setup:--no-wait
@test "$(tfile) Reinstall re-adopts kept user resources and re-adds finalizer" {
    helmer reinstall

    wait_policyserver e2e-cleanup-user

    wait_for --for=condition=PolicyActive clusteradmissionpolicies --all -A
    wait_for --for=condition=PolicyUniquelyReachable clusteradmissionpolicies --all -A

    has_kw_finalizer policyserver e2e-cleanup-user
    kubefail_privileged run pause-privileged-cleanup --image rancher/pause:3.2 --privileged
}

# Cleanup: delete remaining user CRs so the cluster is clean for subsequent
# test files.
@test "$(tfile) Cleanup user resources" {
    kubectl delete clusteradmissionpolicy privileged-pods --wait
    kubectl delete policyserver e2e-cleanup-user --wait
}
