#!/usr/bin/env bats

setup() {
    load common.bash
    wait_pods -n kube-system
}

trigger_audit_scan() {
    local jobname=${1:-testing}
    kubectl delete --ignore-not-found job $jobname --namespace $NAMESPACE
    kubectl create job  --from=cronjob/audit-scanner $jobname  --namespace $NAMESPACE | grep "$jobname created"
    kubectl wait --for=condition="Complete" job $jobname --namespace $NAMESPACE
}

# get_report "pod/podname"
get_report() {
    local resource="$1"
    # Find resource UID
    local ruid=$(kubectl get $resource -o jsonpath='{.metadata.uid}')
    # Figure out if resource report is namespaced or not
    kubectl api-resources --namespaced=false | grep -qw ${resource%/*} && rtype=cpolr || rtype=polr
    # Print resource report
    kubectl get $rtype $ruid -o json
}

# check_report_summary "$report" 2 0
check_report_summary() {
    local report="$1"
    local expected_pass="$2"
    local expected_fail="$3"

    echo "$report" | jq -e ".summary.pass == $expected_pass"
    echo "$report" | jq -e ".summary.fail == $expected_fail"
}

# check_report_result "$report" pass|fail|null [policy_name]
check_report_result() {
    local report="$1"
    local result="$2"
    local policy="$3"

    [[ $result =~ ^(pass|fail|null)$ ]]

    # Policy was not set, check all results
    if [ -z "$policy" ]; then
        echo "$report" | jq -e --arg r $result '.results | all(.result == $r)'
        return
    fi

    if [ "$result" == "null" ]; then
        echo "$report" | jq -e --arg p $policy '.results | all(.policy != $p)'
    else
        echo "$report" | jq -e --arg p $policy --arg r $result '.results | all(select(.policy == $p) | .result == $r)'
    fi
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

    trigger_audit_scan
}

@test "[Audit Scanner] Check cluster wide report results" {
    local r

    # Custom namespace should have failed the audit
    r=$(get_report "ns/testing-audit-scanner")
    check_report_summary "$r" 1 1
    check_report_result "$r" fail clusterwide-safe-labels
    check_report_result "$r" pass clusterwide-psa-label-enforcer-policy

    # Default namespace should pass all checks
    r=$(get_report "ns/default")
    check_report_summary "$r" 2 0
    check_report_result "$r" pass

    # NS nginx-privileged should fail the audit
    r=$(get_report pods/nginx-privileged)
    check_report_summary "$r" 1 1
    check_report_result "$r" fail clusterwide-privileged-pods
    check_report_result "$r" pass clusterwide-safe-labels-for-pods

    # NS nginx-unprivileged should pass the audit
    r=$(get_report pods/nginx-unprivileged)
    check_report_summary "$r" 2 0
    check_report_result "$r" pass clusterwide-privileged-pods
    check_report_result "$r" pass clusterwide-safe-labels-for-pods
}

@test "[Audit Scanner] Delete some policies and retrigger audit scan" {
    kubectl delete -f $RESOURCES_DIR/safe-labels-pods-policy.yaml
    kubectl delete -f $RESOURCES_DIR/namespace-psa-label-enforcer-policy.yaml
    wait_for_default_policy_server_rollout

    trigger_audit_scan
}

@test "[Audit Scanner] Deleted ClusterAdmission policies are removed from audit results" {
    local r

    # Custom namespace pass removed
    r=$(get_report ns/testing-audit-scanner)
    check_report_summary "$r" 0 1
    check_report_result "$r" fail clusterwide-safe-labels
    check_report_result "$r" null clusterwide-psa-label-enforcer-policy

    # Default namespace pass removed
    r=$(get_report ns/default)
    check_report_summary "$r" 1 0
    check_report_result "$r" pass

    # NS nginx-privileged pass removed
    r=$(get_report "pods/nginx-privileged")
    check_report_summary "$r" 0 1
    check_report_result "$r" fail clusterwide-privileged-pods
    check_report_result "$r" null clusterwide-safe-labels-for-pods

    # NS nginx-unprivileged pass removed
    r=$(get_report "pods/nginx-unprivileged")
    check_report_summary "$r" 1 0
    check_report_result "$r" pass clusterwide-privileged-pods
    check_report_result "$r" null clusterwide-safe-labels-for-pods
}

@test "[Audit Scanner] Delete all policy reports after all relevant policies" {
    kubectl delete -f $RESOURCES_DIR/privileged-pod-policy.yaml
    kubectl delete -f $RESOURCES_DIR/safe-labels-namespace.yaml
    wait_for_default_policy_server_rollout

    trigger_audit_scan
    kubectl get policyreport -A 2>&1 | grep 'No resources found'
    kubectl get clusterpolicyreport 2>&1 | grep 'No resources found'
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
