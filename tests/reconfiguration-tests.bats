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
    kubectl run pause-unprivileged --image registry.k8s.io/pause
    wait_for pod pause-unprivileged

    # Launch privileged pod (should fail)
    kubefail_privileged run pause-privileged --image registry.k8s.io/pause --privileged
}
