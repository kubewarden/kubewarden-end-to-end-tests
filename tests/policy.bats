#!/usr/bin/env bats

setup() {
    load ../helpers/helpers.sh
    wait_pods
}

teardown_file() {
    load ../helpers/helpers.sh
    kubectl delete pods --all
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
