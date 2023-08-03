#!/usr/bin/env bats

setup() {
  load common.bash
  wait_pods -n kube-system
}

@test "[Audit Scanner] Install testing policies and resources" {
    # Make sure cronjob was created
    kubectl get cronjob -n kubewarden audit-scanner

    # Launch unprivileged pod
    kubectl run nginx-unprivileged --image=nginx:alpine
    kubectl wait --for=condition=Ready pod nginx-unprivileged

    # Launch privileged pod
    kubectl run nginx-privileged --image=registry.k8s.io/pause --privileged
    kubectl wait --for=condition=Ready pod nginx-privileged

    # Create a namespace to trigger a fail evaluation in the audit scanner
    kubectl create ns testing-audit-scanner
    kubectl label ns testing-audit-scanner cost-center=123

    # Deploy some policy
    apply_cluster_admission_policy $RESOURCES_DIR/privileged-pod-policy.yaml
    apply_cluster_admission_policy $RESOURCES_DIR/namespace-psa-label-enforcer-policy.yaml
    apply_cluster_admission_policy $RESOURCES_DIR/safe-labels-namespace.yaml
}

@test "[Audit Scanner] Trigger audit scanner job" {
    run kubectl get jobs -A
    refute_output -p 'testing'

    run kubectl create job  --from=cronjob/audit-scanner testing  --namespace $NAMESPACE
    assert_output -p "testing created"
    run kubectl wait --for=condition="Complete" job testing --namespace $NAMESPACE
}

@test "[Audit Scanner] Check cluster wide report results" {
    local report=$(kubectl get clusterpolicyreports polr-clusterwide -o json | jq -ec)
    echo "$report" | jq -e '.summary.pass == 13'
    echo "$report" | jq -e '.summary.fail == 1'
    echo "$report" | jq -e '[.results[] | select(.resources[0].name=="default") | .result=="pass"] | all'
    echo "$report" | jq -e '[.results[] | select(.resources[0].name == "testing-audit-scanner" and .policy == "cap-safe-labels")] | all(.result == "fail")'
}

@test "[Audit Scanner] Check namespaced report results" {
    local report=$(kubectl get policyreports polr-ns-default -o json | jq -ec)
    echo "$report" | jq -e '.summary.fail == 1'
    echo "$report" | jq -e '.summary.pass == 1'
    echo "$report" | jq -e '[.results[] | select(.resources[0].name=="nginx-unprivileged") | .result=="pass"] | all'
    echo "$report" | jq -e '[.results[] | select(.resources[0].name=="nginx-privileged") | .result=="fail"] | all'
}

teardown_file() {
    kubectl delete --wait -f $RESOURCES_DIR/privileged-pod-policy.yaml
    kubectl delete --wait -f $RESOURCES_DIR/namespace-label-propagator-policy.yaml
    kubectl delete --wait -f $RESOURCES_DIR/safe-labels-namespace.yaml
    kubectl delete ns testing-audit-scanner
    kubectl delete --wait pod nginx-privileged nginx-unprivileged
}
