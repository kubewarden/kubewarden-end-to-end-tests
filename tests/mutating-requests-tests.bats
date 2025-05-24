#!/usr/bin/env bats

setup() {
    setup_helper
}
teardown_file() {
    teardown_helper
}

# Same as in basic e2e tests?
@test "[Mutation request tests] Test psp-user-group policy with mutating flag enabled" {
    apply_policy mutate-policy-with-flag-enabled.yaml

    # New pod should be mutated by the policy
    kubectl run pause-user-group --image rancher/pause:3.2
    wait_for pod pause-user-group
    kubectl get pod pause-user-group -o json | jq -e ".spec.containers[].securityContext.runAsUser==1000"
    kubectl delete pod pause-user-group

    delete_policy mutate-policy-with-flag-enabled.yaml
}

@test "[Mutation request tests] Test psp-user-group policy with mutating flag disabled" {
    apply_policy mutate-policy-with-flag-disabled.yaml

    # New pod should be rejected by psp-user-group-policy
    run kubectl run pause-user-group --image rancher/pause:3.2
    assert_failure
    assert_output --partial "The policy attempted to mutate the request, but it is currently configured to not allow mutations"

    delete_policy mutate-policy-with-flag-disabled.yaml
}
