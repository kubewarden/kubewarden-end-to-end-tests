#!/usr/bin/env bats

setup() {
    setup_helper
}
teardown_file() {
    teardown_helper
}

@test "$(tfile) Install ClusterAdmissionPolicy in monitor mode" {
    apply_policy privileged-pod-policy-monitor.yaml
}

@test "$(tfile) Monitor mode should only log event" {
    kubectl run nginx-privileged --image=nginx:alpine --privileged
    run kubectl logs -n $NAMESPACE -l app.kubernetes.io/instance=policy-server-default
    assert_output -p "policy evaluation (monitor mode)"
    assert_output -p "allowed: false"
    assert_output -p "Privileged container is not allowed"
    kubectl delete pod nginx-privileged
}

@test "$(tfile) Transition to protect should block events" {
    apply_policy privileged-pod-policy.yaml

    # Launch privileged pod (should fail)
    kubefail_privileged run pod-privileged --image=rancher/pause:3.2 --privileged
}

@test "$(tfile) Transition from protect to monitor should be disallowed" {
    run kubectl apply -f "$RESOURCES_DIR/policies/privileged-pod-policy-monitor.yaml"
    assert_failure
    assert_output --partial "field cannot transition from protect to monitor. Recreate instead."
}
