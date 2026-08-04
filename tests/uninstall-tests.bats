#!/usr/bin/env bats

# Tests for the pre-delete-hook of the admission-controller uninstall
# that runs the controller image in cleanup mode.
# These tests also double as testsuite cleanup step, deleting CRs and CRDs at
# the end.
#
# The uninstall must leave behind ONLY the Kubewarden CRDs and the
# user-defined PolicyServer/policy CRs (with the Kubewarden finalizers
# stripped), so a future re-installation can adopt and reconcile them again.
# Everything that makes the policies run (policy-server Deployments, Services,
# certificate Secrets, ConfigMaps, PodDisruptionBudgets and the webhook
# configurations) must be removed.
#
# For that, we add a test Finalizer that simulates third-party tooling: the
# cleanup must keep it in place and must not hang waiting on resources it does
# not own (the deletion is issued and the cleanup moves on). The finalizer is
# released again by the escape hatch testcase, and the final testcase fails if
# ANY Kubewarden resource (other than the CRDs) is still around. This file thus
# doubles as the suite cleanup: run it last, there is no separate teardown to
# reinstall or to sweep leftovers, so incomplete cleanup cannot be masked.
#
# As a cleanup step, the testcase is idempotent: on a re-run against an already
# uninstalled cluster the install-dependent tests skip, the escape hatch
# no-ops, and the final leftover audit re-runs and enforces the clean state.

# Waiting for pods with wait_pods only makes sense while Kubewarden is
# installed (the first run of this testcase/cleanup). Subsequent runs would
# hang until timeout.
# Therefore, all tests are tagged `setup:--no-wait` which disables the generic
# wait_pods in setup_helper(), and a replacement wait_pods is inside the
# setup(), only run when there's an installed admission-controller.
setup() {
    setup_helper

    # Version check and pod wait only make sense while kubewarden is still
    # installed.
    if helm status -n "$NAMESPACE" admission-controller &>/dev/null; then
        wait_pods -n "$NAMESPACE"
    fi
}

TEST_FINALIZER=e2e.kubewarden.io/test-finalizer
PS_NAME=e2e-uninstall
POLICY_NAME=safe-labels-for-pods

# add_test_finalizer <kind> <name> [-n namespace]
# Idempotent: does nothing if the finalizer is already set (the API server
# rejects duplicate finalizers).
# Also works when the resource has no finalizers array yet
# (a JSON-patch "add /metadata/finalizers/-" would fail on those).
add_test_finalizer() {
    local finalizers
    finalizers=$(kubectl get "$1" "$2" "${@:3}" -o json |
        jq -ce --arg f "$TEST_FINALIZER" '(.metadata.finalizers // []) + [$f] | unique')
    kubectl patch "$1" "$2" "${@:3}" --type=merge -p "{\"metadata\":{\"finalizers\":$finalizers}}"
}

# release_test_finalizer <kind> <name> [-n namespace]
# Idempotent: does nothing if the resource is already gone.
release_test_finalizer() {
    local json finalizers
    json=$(kubectl get "$1" "$2" "${@:3}" -o json 2>/dev/null) || return 0
    finalizers=$(jq -ce --arg f "$TEST_FINALIZER" '.metadata.finalizers // [] | map(select(. != $f))' <<<"$json")
    kubectl patch "$1" "$2" "${@:3}" --type=merge -p "{\"metadata\":{\"finalizers\":$finalizers}}"
}

# Skip tests if no installed kubewarden, so the whole file is idempotent and
# converges on the final audit.
skip_uninstalled() {
    helm status -n "$NAMESPACE" admission-controller &>/dev/null || skip "kubewarden is not installed"
}

# bats test_tags=setup:--no-wait
@test "$(tfile) Prepare user resources with test finalizers" {
    # test requires an installed kubewarden
    skip_uninstalled

    # User-defined PolicyServer with a policy assigned to it
    create_policyserver $PS_NAME
    apply_policy_for_ps $PS_NAME safe-labels-pods-policy.yaml

    # Sanity: both CRs carry the Kubewarden finalizer
    kubectl get ps $PS_NAME -o json | jq -e '.metadata.finalizers | any(startswith("kubewarden"))'
    kubectl get cap $POLICY_NAME -o json | jq -e '.metadata.finalizers | any(startswith("kubewarden"))'

    # Sanity: resources backing the user policy-server exist
    kubectl get deployment,service,secret,configmap,pdb -n "$NAMESPACE" -l kubewarden/policy-server=$PS_NAME

    # Simulate third-party tooling: the cleanup must keep this finalizer on
    # the user CR while stripping the Kubewarden ones
    add_test_finalizer ps $PS_NAME

    # and must not hang on a policy-server resource it cannot fully
    # delete: the deletion is issued and the cleanup moves on
    add_test_finalizer configmap policy-server-$PS_NAME -n "$NAMESPACE"
}

# bats test_tags=setup:--no-wait
@test "$(tfile) Uninstall runs the pre-delete hook cleanup" {
    # test requires an installed kubewarden
    skip_uninstalled

    helmer uninstall

    # The pre-delete Job is removed on success (hook-delete-policy: hook-succeeded)
    run kubectl get jobs -n "$NAMESPACE"
    refute_output -p controller

    # Controller and all policy-server deployments are gone
    run kubectl get deployments -n "$NAMESPACE"
    refute_output -p controller
    refute_output -p policy-server

    # No Kubewarden webhook configurations are left behind (orphaned webhooks
    # without a policy-server would DoS the cluster)
    run kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations -l app.kubernetes.io/part-of=kubewarden
    assert_output -p "No resources found"

    # CRDs are kept (helm.sh/resource-policy: keep)
    kubectl get crds policyservers.policies.kubewarden.io
    kubectl get crds clusteradmissionpolicies.policies.kubewarden.io

    # User CRs are kept: Kubewarden finalizers stripped, test finalizer kept
    kubectl get ps $PS_NAME -o json | jq -e --arg f "$TEST_FINALIZER" '.metadata.finalizers == [$f]'
    kubectl get cap $POLICY_NAME -o json | jq -e '.metadata.finalizers // [] | length == 0'

    # The user CRs must not be terminating: they are kept for re-installation
    kubectl get ps $PS_NAME -o json | jq -e '.metadata.deletionTimestamp == null'
    kubectl get cap $POLICY_NAME -o json | jq -e '.metadata.deletionTimestamp == null'

    # Chart-managed default CRs (default PolicyServer, recommended policies) are gone
    run kubectl get ps,cap,capg,ap,apg -A -l kubewarden.io/managed-by=kubewarden-controller-defaults
    assert_output -p "No resources found"

    # The policy-server ConfigMap held by the test finalizer: the deletion
    # was issued (terminating) but the cleanup did not wait for it
    kubectl get configmap policy-server-$PS_NAME -n "$NAMESPACE" -o json |
        jq -e '.metadata.deletionTimestamp != null'

    # All other resources backing the user policy-server are swept
    run kubectl get deployment,service,secret,pdb -n "$NAMESPACE" -l kubewarden/policy-server=$PS_NAME
    assert_output -p "No resources found"

    # The uninstall is only complete once the deleted pods finish their
    # termination grace period; the leftover audit relies on this
    kubectl wait --for=delete --timeout=60s pods -A -l app.kubernetes.io/part-of=kubewarden
}

# bats test_tags=setup:--no-wait
@test "$(tfile) Escape hatch: resources are deletable once finalizers are released" {
    # Releasing the test finalizer completes the ConfigMap deletion issued
    # by the cleanup (already-gone means success, so this is re-run safe).
    release_test_finalizer configmap policy-server-$PS_NAME -n "$NAMESPACE"
    kubectl wait --for=delete --timeout=30s configmap policy-server-$PS_NAME -n "$NAMESPACE"

    release_test_finalizer ps $PS_NAME

    # Without a running controller, plain kubectl delete must complete on its own
    kubectl delete --ignore-not-found --timeout=30s cap $POLICY_NAME
    kubectl delete --ignore-not-found --timeout=30s ps $PS_NAME
}

# bats test_tags=setup:--no-wait
@test "$(tfile) Nothing is left over after the uninstall" {
    # No Helm releases are left in the namespace
    run helm list -n "$NAMESPACE" -q
    assert_output ""

    # No Kubewarden CRs are left: the previous testcases removed the
    # intentionally kept user CRs, and every other CR created by the test
    # suite or the charts must be gone.
    # On a re-run the CRDs were already removed below, and no CRs can exist
    # without them.
    if kubectl get crds policyservers.policies.kubewarden.io &>/dev/null; then
        run kubectl get ps,ap,cap,apg,capg -A
        assert_output -p "No resources found"
    fi

    # Nothing labeled as part of Kubewarden survived, namespaced...
    run kubectl get all,jobs,secrets,configmaps,pdb,serviceaccounts,leases -A -l app.kubernetes.io/part-of=kubewarden
    assert_output -p "No resources found"

    # ...or cluster-scoped
    run kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations,clusterroles,clusterrolebindings -l app.kubernetes.io/part-of=kubewarden
    assert_output -p "No resources found"

    # No policy-server backing resources survived
    run kubectl get all,secrets,configmaps,pdb -A -l app.kubernetes.io/component=policy-server
    assert_output -p "No resources found"

    # Only the CRDs remain, kept on purpose for re-installation.
    local crds
    crds=$(kubectl get crds -o name | grep '\.kubewarden\.io$' || true)
    [ -z "$crds" ] || [ "$(wc -l <<<"$crds")" -eq 5 ] # the 5 policies CRDs, nothing else

    # Remove CRDs and CRs for a complete cleanup
    [ -z "$crds" ] || kubectl delete --timeout=60s $crds

    # Nothing Kubewarden-related is left in the cluster
    run kubectl get crds -o name
    refute_output -p kubewarden.io
}
