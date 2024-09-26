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

# Create pod-privileged policy to block CREATE & UPDATE of privileged pods
@test "[Basic end-to-end tests] Apply pod-privileged policy that blocks CREATE & UPDATE" {
    apply_policy privileged-pod-policy.yaml

    # Launch unprivileged pod
    kubectl run nginx-unprivileged --image=nginx:alpine
    kubectl wait --for=condition=Ready pod nginx-unprivileged

    # Launch privileged pod (should fail)
    kubefail_privileged run pod-privileged --image=registry.k8s.io/pause --privileged
}

# Update pod-privileged policy to block only UPDATE of privileged pods
@test  "[Basic end-to-end tests] Patch policy to block only UPDATE operation" {
    yq '.spec.rules[0].operations = ["UPDATE"]' $RESOURCES_DIR/policies/privileged-pod-policy.yaml | kubectl apply -f -

    # I can create privileged pods now
    kubectl run nginx-privileged --image=nginx:alpine --privileged

    # I can not update privileged pods
    kubefail_privileged label pod nginx-privileged x=y
}

@test "[Basic end-to-end tests] Delete ClusterAdmissionPolicy" {
    delete_policy privileged-pod-policy.yaml

    # I can update privileged pods now
    kubectl label pod nginx-privileged x=y
}

@test "[Basic end-to-end tests] Apply mutating psp-user-group AdmissionPolicy" {
    apply_policy psp-user-group-policy.yaml

    # Policy should mutate pods
    kubectl run pause-user-group --image registry.k8s.io/pause
    kubectl wait --for=condition=Ready pod pause-user-group
    kubectl get pods pause-user-group -o json | jq -e ".spec.containers[].securityContext.runAsUser==1000"

    delete_policy psp-user-group-policy.yaml
}

@test "[Basic end-to-end tests] Launch & scale second policy server" {
    kubectl apply -f $RESOURCES_DIR/policy-server.yaml
    wait_for policyserver e2e-tests --for=condition=ServiceReconciled

    kubectl patch policyserver e2e-tests --type=merge -p '{"spec": {"replicas": 2}}'
    wait_policyserver e2e-tests

    kubectl delete -f $RESOURCES_DIR/policy-server.yaml
}
