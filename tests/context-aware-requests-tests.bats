#!/usr/bin/env bats

setup() {
    load ../helpers/helpers.sh
    wait_pods
}

teardown_file() {
    load ../helpers/helpers.sh
    kubectl delete pods --all
    kubectl delete admissionpolicies,clusteradmissionpolicies --all -A
}

# Same as in basic e2e tests?
@test "[Context Aware Policy tests] Test mutating a Pod" {
    apply_policy context-aware-policy.yaml

    # Create Pod with the right annotation
    kubectl create ns ctx-test
    kubectl annotate namespaces ctx-test propagate.hello=world

    kubectl run --namespace ctx-test pause-user-group --image registry.k8s.io/pause
    kubectl wait --for=condition=Ready pod --namespace ctx-test pause-user-group
    kubectl get pod --namespace ctx-test pause-user-group -o json | jq -e '.metadata.labels["hello"]=="world"'
    kubectl delete namespace ctx-test

    delete_policy context-aware-policy.yaml
}
