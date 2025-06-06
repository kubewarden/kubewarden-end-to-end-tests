#!/usr/bin/env bats

setup() {
    setup_helper
}
teardown_file() {
    teardown_helper
}

@test "[Reconfiguration tests] Apply pod-privileged policy" {
    apply_policy privileged-pod-policy.yaml
}

@test "[Reconfiguration tests] Reconfigure Kubewarden stack" {
    helmer set kubewarden-controller --values=$RESOURCES_DIR/reconfiguration-values.yaml
    wait_for --for=condition="PolicyActive" clusteradmissionpolicies --all
}

@test "[Reconfiguration tests] Apply psp-user-group policy" {
    apply_policy psp-user-group-policy.yaml
}

@test "[Reconfiguration tests] Test that pod-privileged policy works" {
    # Launch unprivileged pod
    kubectl run pause-unprivileged --image rancher/pause:3.2
    wait_for pod pause-unprivileged

    # Launch privileged pod (should fail)
    kubefail_privileged run pause-privileged --image rancher/pause:3.2 --privileged
}
