#!/usr/bin/env bats

setup() {
    load ../helpers/helpers.sh
    wait_pods
}

teardown_file() {
    load ../helpers/helpers.sh
    kubectl delete pods --all
    kubectl delete ap,cap,capg --all -A
}

@test "[Basic end-to-end tests] Helm app version is consistent" {
    helm list -n $NAMESPACE -o json | jq 'map(.app_version) | unique | length == 1'
}

# Create pod-privileged policy to block CREATE & UPDATE of privileged pods
@test "[Basic end-to-end tests] Apply pod-privileged policy that blocks CREATE & UPDATE" {
    apply_policy privileged-pod-policy.yaml

    # Launch unprivileged pod
    kubectl run nginx-unprivileged --image=nginx:alpine
    wait_for pod nginx-unprivileged

    # Launch privileged pod (should fail)
    kubefail_privileged run pod-privileged --image=rancher/pause:3.2 --privileged
}

# Update pod-privileged policy to block only UPDATE of privileged pods
@test "[Basic end-to-end tests] Patch policy to block only UPDATE operation" {
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
    kubectl run pause-user-group --image rancher/pause:3.2
    wait_for pod pause-user-group
    kubectl get pods pause-user-group -o json | jq -e ".spec.containers[].securityContext.runAsUser==1000"

    delete_policy psp-user-group-policy.yaml
}

@test "[Basic end-to-end tests] Launch & scale second policy server" {
    create_policyserver e2e-tests
    wait_for policyserver e2e-tests --for=condition=ServiceReconciled

    kubectl patch policyserver e2e-tests --type=merge -p '{"spec": {"replicas": 2}}'
    wait_policyserver e2e-tests

    kubectl delete ps e2e-tests
}
