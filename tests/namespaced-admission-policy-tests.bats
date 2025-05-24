#!/usr/bin/env bats

setup() {
    setup_helper
}
teardown_file() {
    teardown_helper
}

@test "[Namespaced AdmissionPolicy] Test AdmissionPolicy in default NS" {
    apply_policy policy-pod-privileged.yaml

    # Privileged pod in the default namespace (should fail)
    kubefail_privileged run nginx-privileged --image=nginx:alpine --privileged

    # Privileged pod in the kubewarden namespace (should work)
    kubectl run nginx-privileged --image=nginx:alpine --privileged -n $NAMESPACE
    wait_for pod nginx-privileged -n $NAMESPACE
    kubectl delete pod nginx-privileged -n $NAMESPACE

    # Unprivileged pod in default namespace (should work)
    kubectl run nginx-unprivileged --image=nginx:alpine
    wait_for pod nginx-unprivileged
    kubectl delete pod nginx-unprivileged
}

@test  "[Namespaced AdmissionPolicy] Update policy to check only UPDATE operations" {
    yq '.spec.rules[0].operations = ["UPDATE"]' $RESOURCES_DIR/policies/policy-pod-privileged.yaml | kubectl apply -f -

    # I can create privileged pods now
    kubectl run nginx-privileged --image=nginx:alpine --privileged

    # I still can not update privileged pods
    kubefail_privileged label pod nginx-privileged x=y
    kubectl delete pod nginx-privileged
}

@test "[Namespaced AdmissionPolicy] Delete AdmissionPolicy to check restrictions are removed" {
    delete_policy policy-pod-privileged.yaml

    # I can create privileged pods
    kubectl run nginx-privileged --image=nginx:alpine --privileged

    # I can update privileged pods
    kubectl label pod nginx-privileged x=y
}
