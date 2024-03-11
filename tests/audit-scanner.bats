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
    run kubectl create job  --from=cronjob/audit-scanner testing  --namespace $NAMESPACE
    assert_output -p "testing created"
    kubectl wait --for=condition="Complete" job testing --namespace $NAMESPACE
}

@test "[Audit Scanner] Check cluster wide report results" {
    testing_namespace_uid=$(kubectl get ns testing-audit-scanner -o=json | jq -r ".metadata.uid")
    local report=$(kubectl get clusterpolicyreports "$testing_namespace_uid" -o json | jq -ec)
    echo "$report" | jq -e '.summary.pass == 1'
    echo "$report" | jq -e '.summary.fail == 1'
    echo "$report" | jq -e '[.results[] | select(.policy == "clusterwide-safe-labels")] | all(.result == "fail")'
    echo "$report" | jq -e '[.results[] | select(.policy == "clusterwide-psa-label-enforcer-policy")] | all(.result == "pass")'
    default_namespace_uid=$(kubectl get ns default -o=json | jq -r ".metadata.uid")
    local report=$(kubectl get clusterpolicyreports "$default_namespace_uid" -o json | jq -ec)
    echo "$report" | jq -e '.summary.pass == 2'
    echo "$report" | jq -e '.summary.fail == 0'
    echo "$report" | jq -e '[.results[] | select(.result=="pass")] | all'
}

@test "[Audit Scanner] Check namespaced report results" {
    privileged_pod_uid=$(kubectl get pods nginx-privileged  -o=json | jq -r ".metadata.uid")
    local report=$(kubectl get policyreports "$privileged_pod_uid" -o json | jq -ec)
    echo "$report" | jq -e '.summary.fail == 1'
    echo "$report" | jq -e '.summary.pass == 0'
    echo "$report" | jq -e '[.results[] | select(.policy == "clusterwide-privileged-pods") | .result=="fail"] | all'

    unprivileged_pod_uid=$(kubectl get pods nginx-unprivileged  -o=json | jq -r ".metadata.uid")
    local report=$(kubectl get policyreports "$unprivileged_pod_uid" -o json | jq -ec)
    echo "$report" | jq -e '.summary.fail == 0'
    echo "$report" | jq -e '.summary.pass == 1'
    echo "$report" | jq -e '[.results[] | select(.policy == "clusterwide-privileged-pods") | .result=="pass"] | all'
}

teardown_file() {
    kubectl delete -f $RESOURCES_DIR/privileged-pod-policy.yaml
    kubectl delete -f $RESOURCES_DIR/namespace-label-propagator-policy.yaml
    kubectl delete -f $RESOURCES_DIR/safe-labels-namespace.yaml
    kubectl delete ns testing-audit-scanner
    kubectl delete pod nginx-privileged nginx-unprivileged
    kubectl delete jobs -n kubewarden testing
}
