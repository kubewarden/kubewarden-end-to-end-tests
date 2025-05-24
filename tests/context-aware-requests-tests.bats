#!/usr/bin/env bats

setup() {
    setup_helper
}
teardown_file() {
    teardown_helper
}

# Same as in basic e2e tests?
@test "[Context Aware Policy tests] Test mutating a Pod" {
    apply_policy context-aware-policy.yaml

    # Create Pod with the right annotation
    kubectl create ns ctx-test
    kubectl annotate namespaces ctx-test propagate.hello=world

    kubectl run --namespace ctx-test pause-user-group --image rancher/pause:3.2
    wait_for pod --namespace ctx-test pause-user-group
    kubectl get pod --namespace ctx-test pause-user-group -o json | jq -e '.metadata.labels["hello"]=="world"'
    kubectl delete namespace ctx-test

    delete_policy context-aware-policy.yaml
}
