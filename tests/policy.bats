#!/usr/bin/env bats

setup() {
    load ../helpers/helpers.sh
    wait_pods
}

teardown_file() {
    load ../helpers/helpers.sh
    kubectl delete pods --all
    kubectl delete ap,cap,capg --all -A
    kubectl delete ns shouldbeignored --ignore-not-found
    helmer reset kubewarden-defaults
}

# Number of policies included in the recommended policies
POLICY_NUMBER=6

@test "[Recommended policies] Install policies in protect mode" {
    helmer set kubewarden-defaults \
        --set recommendedPolicies.enabled=True \
        --set recommendedPolicies.defaultPolicyMode=protect \
        --set recommendedPolicies.skipAdditionalNamespaces[0]='shouldbeignored'

    # Wait for policies be enforced
    wait_policies PolicyUniquelyReachable

    # Check we get the correct recommended policies number
    kubectl --no-headers=true get ap,cap,apg,capg -A | wc -l | grep -qx $POLICY_NUMBER
}

@test "[Recommended policies] Check that policies are enforced" {
    # Test privileged pod (should fail)
    kubefail_privileged run pod-privileged --image=rancher/pause:3.2 --privileged

    # Test allow privileged escalation psp policy
    run ! kuberun --overrides='{"spec":{"containers":[{"name":"nginx-denied-privi-escalation","image":"busybox","securityContext":{"allowPrivilegeEscalation":true}}]}}'
    assert_output --regexp '^Error.*: admission webhook.*denied the request.*containers has privilege escalation enabled$'

    # Test host namespace psp policy
    run ! kuberun --overrides='{"spec": {"hostNetwork": true}}'
    assert_output --regexp '^Error.*: admission webhook.*denied the request.*Pod has host network enabled, but this is not allowed$'

    # Test user group psp policy
    run ! kuberun --overrides='{"spec": {"securityContext": {"runAsUser": 0}}}'
    assert_output --regexp '^Error.*: admission webhook.*denied the request.*Invalid user ID: cannot run container with root ID \(0\)$'

    # Test hostpath psp policy
    run ! kuberun --overrides='{"spec":{"containers":[{"name":"hostpath-denied","image":"busybox","volumeMounts":[{"name":"host-volume","mountPath":"/mnt"}]}],"volumes":[{"name":"host-volume","hostPath":{"path":"/mnt","type":"DirectoryOrCreate"}}]}}'
    assert_output --regexp '^Error.*: admission webhook.*denied the request.*hostPath.*mounted as.*is not in the AllowedHostPaths list$'

    # Test capablities psp policy
    run ! kuberun --overrides='{"spec":{"containers":[{"name":"net-admin-denied","image":"busybox","securityContext":{"capabilities":{"add":["NET_ADMIN"]}}}]}}'
    assert_output --regexp '^Error.*: admission webhook.*denied the request.*PSP capabilities policies.*to be added.*$'

    # Test privileged pod in the ignored namespace (should work according to helm chart options)
    kubectl create ns shouldbeignored
    kuberun --privileged -n shouldbeignored
}

@test "[Recommended policies] Disable policies & run privileged pod" {
    helmer set kubewarden-defaults --set recommendedPolicies.enabled=False
    kubectl run pod-privileged --image=rancher/pause:3.2 --privileged
    kubectl delete pod pod-privileged
}

@test "[Rego policy] Apply rego policy to block nginx image usage" {
    apply_policy rego-block-image-policy.yaml

    run ! kuberun --image=nginx
    assert_output --regexp '^Error.*: admission webhook.*denied the request.*These images should be blocked.*$'
    delete_policy rego-block-image-policy.yaml
}

@test "[CEL policies] Apply CEL policy to block deployment with replicas < 3" {
    apply_policy cel-policy.yaml

    # Deployment should fail because replicas < 3
    run ! kubectl create deployment cel-policy-test --image nginx --replicas 2
    assert_output --regexp '^error:.*admission webhook.*denied the request.*The number of replicas must be greater than or equal to 3$'

    # Deployment should work because replicas >= 3
    kubectl create deployment cel-policy-test --image nginx --replicas 3
    kubectl delete deployment cel-policy-test
    delete_policy cel-policy.yaml
}

@test "[Policy group] Apply policy group to block privileged escalation and shared pid namespace pods" {
    apply_policy policy-group-escalation-shared-pid.yaml

    # I can not create pod using privileged escalation only
    kubefail_policy_group run nginx-denied-privi-escalation --image=nginx:alpine \
        --overrides='{"spec":{"containers":[{"name":"nginx-denied-privi-escalation","image":"nginx:alpine","securityContext":{"allowPrivilegeEscalation":true}}]}}'

    # I can not create pod using shared pid namespace only
    kubefail_policy_group run nginx-denied-shared-pid --image=nginx:alpine \
        --overrides='{"spec":{"shareProcessNamespace":true}}'

    # I can create pod using shared pid namespace with the mandatory annotation
    kubectl run nginx-shared-pid --image=nginx:alpine --annotations="super_pod=true" \
        --overrides='{"spec":{"shareProcessNamespace":true}}'

    # I can create pod using privileged escalation with the mandatory annotation
    kubectl run nginx-privi-escalation --image=nginx:alpine --annotations="super_pod=true" \
        --overrides='{"spec":{"containers":[{"name":"nginx-privi-escalation","image":"nginx:alpine","securityContext":{"allowPrivilegeEscalation":true}}]}}'

    # I can create pod using privileged escalation and shared pid namespace with the mandatory annotation
    kubectl run nginx-privi-escalation-shared-pid --image=nginx:alpine --annotations="super_pod=true" \
        --overrides='{"spec":{"shareProcessNamespace":true,"containers":[{"name":"nginx-privi-escalation-shared-pid","image":"nginx:alpine","securityContext":{"allowPrivilegeEscalation":true}}]}}'

    delete_policy policy-group-escalation-shared-pid.yaml
}
