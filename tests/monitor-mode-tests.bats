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

@test "[Monitor mode end-to-end tests] Install ClusterAdmissionPolicy in monitor mode" {
    apply_policy privileged-pod-policy-monitor.yaml
}

@test "[Monitor mode end-to-end tests] Monitor mode should only log event" {
    kubectl run nginx-privileged --image=nginx:alpine --privileged
    run kubectl logs -n $NAMESPACE -lapp="kubewarden-policy-server-default"
    assert_output -p "policy evaluation (monitor mode)"
    assert_output -p "allowed: false"
    assert_output -p "Privileged container is not allowed"
    kubectl delete pod nginx-privileged
}

@test "[Monitor mode end-to-end tests] Transition to protect should block events" {
    apply_policy privileged-pod-policy.yaml

    # Launch privileged pod (should fail)
    kubefail_privileged run pod-privileged --image=registry.k8s.io/pause --privileged
}

@test "[Monitor mode end-to-end tests] Transition from protect to monitor should be disallowed" {
    run kubectl apply -f "$RESOURCES_DIR/policies/privileged-pod-policy-monitor.yaml"
    assert_failure
    assert_output --partial "field cannot transition from protect to monitor. Recreate instead."
}
