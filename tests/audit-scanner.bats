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
    kubectl apply -f $RESOURCES_DIR/privileged-pod-policy.yaml
    kubectl apply -f $RESOURCES_DIR/namespace-psa-label-enforcer-policy.yaml
    kubectl apply -f $RESOURCES_DIR/safe-labels-namespace.yaml
    apply_cluster_admission_policy $RESOURCES_DIR/safe-labels-pods-policy.yaml
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
    echo "$report" | jq -e '.summary.pass == 1'
    echo "$report" | jq -e '[.results[] | select(.policy == "clusterwide-privileged-pods") | .result=="fail"] | all'
    echo "$report" | jq -e '[.results[] | select(.policy == "clusterwide-safe-labels-for-pods") | .result=="pass"] | all'

    unprivileged_pod_uid=$(kubectl get pods nginx-unprivileged  -o=json | jq -r ".metadata.uid")
    local report=$(kubectl get policyreports "$unprivileged_pod_uid" -o json | jq -ec)
    echo "$report" | jq -e '.summary.fail == 0'
    echo "$report" | jq -e '.summary.pass == 2'
    echo "$report" | jq -e '[.results[] | select(.policy == "clusterwide-privileged-pods") | .result=="pass"] | all'
    echo "$report" | jq -e '[.results[] | select(.policy == "clusterwide-safe-labels-for-pods") | .result=="pass"] | all'

}

@test "[Audit Scanner] Delete some policies and retrigger audit scanner job" {
    kubectl delete -f $RESOURCES_DIR/safe-labels-pods-policy.yaml
    kubectl delete -f $RESOURCES_DIR/namespace-psa-label-enforcer-policy.yaml
    wait_for_default_policy_server_rollout
    
    kubectl delete --ignore-not-found job testing --namespace $NAMESPACE
    run kubectl create job  --from=cronjob/audit-scanner testing  --namespace $NAMESPACE
    assert_success
    assert_output -p "testing created"
    kubectl wait --for=condition="Complete" job testing --namespace $NAMESPACE
}

@test "[Audit Scanner] Update cluster wide report results" {
    testing_namespace_uid=$(kubectl get ns testing-audit-scanner -o=json | jq -r ".metadata.uid")
    local report=$(kubectl get clusterpolicyreports "$testing_namespace_uid" -o json | jq -ec)
    echo "$report" | jq -e '.summary.pass == 0'
    echo "$report" | jq -e '.summary.fail == 1'
    echo "$report" | jq -e '[.results[] | select(.policy == "clusterwide-safe-labels")] | all(.result == "fail")'
    echo "$report" | jq '[.results[] | select(.policy == "clusterwide-psa-label-enforcer-policy")] | empty'

    default_namespace_uid=$(kubectl get ns default -o=json | jq -r ".metadata.uid")
    local report=$(kubectl get clusterpolicyreports "$default_namespace_uid" -o json | jq -ec)
    echo "$report" | jq -e '.summary.pass == 1'
    echo "$report" | jq -e '.summary.fail == 0'
    echo "$report" | jq -e '[.results[] | select(.result=="pass")] | all'
}

@test "[Audit Scanner] Update namespaced policy reports after remove one policy" {

    unprivileged_pod_uid=$(kubectl get pods nginx-unprivileged  -o=json | jq -r ".metadata.uid")
    local report=$(kubectl get policyreports "$unprivileged_pod_uid" -o json | jq -ec)
    echo "$report" | jq -e '.summary.fail == 0'
    echo "$report" | jq -e '.summary.pass == 1'
    echo "$report" | jq -e '[.results[] | select(.policy == "clusterwide-privileged-pods") | .result=="pass"] | all'
    echo "$report" | jq '[.results[] | select(.policy == "clusterwide-safe-labels-for-pods")] | empty'

    privileged_pod_uid=$(kubectl get pods nginx-privileged  -o=json | jq -r ".metadata.uid")
    local report=$(kubectl get policyreports "$privileged_pod_uid" -o json | jq -ec)
    echo "$report" | jq -e '.summary.fail == 1'
    echo "$report" | jq -e '.summary.pass == 0'
    echo "$report" | jq -e '[.results[] | select(.policy == "clusterwide-privileged-pods") | .result=="fail"] | all'
    echo "$report" | jq '[.results[] | select(.policy == "clusterwide-safe-labels-for-pods")] | empty'
}

@test "[Audit Scanner] Delete all policy reports after all relevant policies" {
    kubectl delete -f $RESOURCES_DIR/privileged-pod-policy.yaml
    kubectl delete -f $RESOURCES_DIR/safe-labels-namespace.yaml
    wait_for_default_policy_server_rollout

    kubectl delete --ignore-not-found job testing --namespace $NAMESPACE
    run kubectl create job  --from=cronjob/audit-scanner testing  --namespace $NAMESPACE
    assert_success
    assert_output -p "testing created"
    kubectl wait --for=condition="Complete" job testing --namespace $NAMESPACE

    retry "kubectl get --ignore-not-found policyreport -A -o json | jq -e '.items[] | empty'"
    retry "kubectl get --ignore-not-found clusterpolicyreport -A -o json | jq -e '.items[] | empty'"
}

teardown_file() {
    kubectl delete --ignore-not-found -f $RESOURCES_DIR/privileged-pod-policy.yaml
    kubectl delete --ignore-not-found -f $RESOURCES_DIR/namespace-label-propagator-policy.yaml
    kubectl delete --ignore-not-found -f $RESOURCES_DIR/safe-labels-namespace.yaml
    kubectl delete --ignore-not-found -f $RESOURCES_DIR/safe-labels-pods-policy.yaml
    kubectl delete --ignore-not-found ns testing-audit-scanner
    kubectl delete --ignore-not-found pod nginx-privileged nginx-unprivileged
    kubectl delete --ignore-not-found jobs -n kubewarden testing

}
