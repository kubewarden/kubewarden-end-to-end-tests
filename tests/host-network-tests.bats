#!/usr/bin/env bats

# Host network tests validate enabling/disabling hostNetwork on single-node
# clusters, controller and PolicyServer port changes, and policy evaluation
# across all transitions.
#
# IMPORTANT: With hostNetwork=true, controller and PolicyServer share the host
# network namespace. Default ports will conflict on single-node clusters:
#   - Controller healthProbe (8081) vs PolicyServer readinessProbePort (8081)
# Custom webhookPort and readinessProbePort are REQUIRED to avoid bind failures;
# these two fields actually change the port the pod binds on the host (via
# KUBEWARDEN_PORT and KUBEWARDEN_READINESS_PROBE_PORT env vars). When changing
# these host ports on a single-node cluster, they must be changed together to
# prevent the new pod from conflicting with ports still held by the old pod
# during rollout.
#
# Flow (tests run sequentially and share state):
#   1. Enable hostNetwork + custom ports + policy eval
#   2. Controller port change (all three ports) with hostNetwork enabled
#   3. Add second PolicyServer with custom ports + policy eval
#   4. PolicyServer CRD port update on second PS + policy eval
#   5. Disable hostNetwork + change controller ports + verify + policy eval
#
# Port allocation:
#   Controller (initial):  webhook=63000 healthProbe=63001 metrics=63002
#   Controller (step 2):   webhook=63100 healthProbe=63101 metrics=63102
#   Controller (step 5):   webhook=63200 healthProbe=63201 metrics=63202
#   Default PS host ports: webhookPort=64005 readinessProbePort=63003
#   user-ps host ports (initial):  webhookPort=62000 readinessProbePort=62001
#   user-ps host ports (step 4):   webhookPort=62100 readinessProbePort=62101

setup() {
    setup_helper
    load "../helpers/hostnetwork.sh"
}

teardown_file() {
    teardown_helper

    # Clean up second PolicyServer
    kubectl delete policyserver user-ps --ignore-not-found --wait

    # Reset kubewarden to defaults
    helmer reset kubewarden-controller
    helmer reset kubewarden-defaults
}


@test "$(tfile) Enable hostNetwork with custom ports and verify policy evaluation" {
    # Single-node friendly setup: one PolicyServer replica, no anti-affinity.
    # Custom ports avoid conflicts between controller and PolicyServer.
    # IMPORTANT: set custom ports on defaults BEFORE enabling hostNetwork on
    # the controller, so the reconciler never creates a PS with default ports
    # that would collide on the host.
    helmer set kubewarden-defaults \
        --set policyServer.replicaCount=1 \
        --set policyServer.readinessProbePort=63003 \
        --set policyServer.webhookPort=64005

    helmer set kubewarden-controller --set hostNetwork=true \
        --set ports.webhook=63000 \
        --set ports.healthProbe=63001 \
        --set ports.metrics=63002

    wait_rollout deployment/kubewarden-controller

    # Verify hostNetwork is enabled on both controller and policy-server
    assert_deployment_hostnetwork "app.kubernetes.io/name=kubewarden-controller" "true"
    assert_deployment_hostnetwork "kubewarden/policy-server=default" "true"

    # Verify DNS policy is set correctly for hostNetwork pods
    local policyserver_dns
    policyserver_dns=$(kubectl get deployment -n "$NAMESPACE" -l kubewarden/policy-server=default \
        -o jsonpath='{.items[0].spec.template.spec.dnsPolicy}')
    [[ "$policyserver_dns" == "ClusterFirstWithHostNet" ]]

    # Deploy a policy and test admission
    apply_policy privileged-pod-policy.yaml

    # Unprivileged pod should succeed
    kuberun --image=rancher/pause:3.2

    # Privileged pod should be blocked
    kubefail_privileged run pod-privileged-hostnet --image=rancher/pause:3.2 --privileged

    delete_policy privileged-pod-policy.yaml
}


@test "$(tfile) Controller port change with hostNetwork enabled" {
    # Change ALL three controller ports while hostNetwork is active.
    # All ports must change together to avoid bind conflicts during rollout.
    helmer set kubewarden-controller \
        --set ports.webhook=63100 \
        --set ports.healthProbe=63101 \
        --set ports.metrics=63102
    wait_rollout deployment/kubewarden-controller

    # Verify the controller container port changed
    local container_port
    container_port=$(kubectl get deployment -n "$NAMESPACE" kubewarden-controller \
        -o jsonpath='{.spec.template.spec.containers[0].ports[?(@.name=="webhook-server")].containerPort}')
    [[ "$container_port" == "63100" ]]

    # Verify the webhook service targetPort changed
    local target_port
    target_port=$(kubectl get svc -n "$NAMESPACE" kubewarden-controller-webhook-service \
        -o jsonpath='{.spec.ports[0].targetPort}')
    [[ "$target_port" == "63100" ]]

    # Default PolicyServer should still have hostNetwork enabled
    assert_deployment_hostnetwork "kubewarden/policy-server=default" "true"
}


@test "$(tfile) Add second PolicyServer with custom ports under hostNetwork" {
    # Create a second PolicyServer with non-overlapping custom ports.
    # Default PS uses 64005/63003; user-ps uses 62000/62001.
    create_policyserver_with_ports user-ps 62000 62001

    # Verify hostNetwork is enabled on both PolicyServers
    assert_deployment_hostnetwork "kubewarden/policy-server=default" "true"
    assert_deployment_hostnetwork "kubewarden/policy-server=user-ps" "true"

    # Verify DNS policy on the second PolicyServer
    local userps_dns
    userps_dns=$(kubectl get deployment -n "$NAMESPACE" -l kubewarden/policy-server=user-ps \
        -o jsonpath='{.items[0].spec.template.spec.dnsPolicy}')
    [[ "$userps_dns" == "ClusterFirstWithHostNet" ]]

    # Deploy a policy and test admission
    apply_policy privileged-pod-policy.yaml

    # Unprivileged pod should succeed
    kuberun --image=rancher/pause:3.2

    # Privileged pod should be blocked
    kubefail_privileged run pod-privileged-multi-ps --image=rancher/pause:3.2 --privileged

    # Clean up policies (keep user-ps alive for next test)
    delete_policy privileged-pod-policy.yaml
}


@test "$(tfile) PolicyServer CRD port update with hostNetwork enabled" {
    # Patch user-ps to change host ports.
    # Original ports: webhookPort=62000, readinessProbePort=62001
    # New ports:      webhookPort=62100, readinessProbePort=62101
    kubectl patch policyserver user-ps --type=merge \
        -p '{"spec": {"webhookPort": 62100, "readinessProbePort": 62101}}'
    wait_policyserver user-ps

    # Verify the deployment env vars reflect the new ports
    local kw_port kw_readiness_port
    kw_port=$(kubectl get deployment -n "$NAMESPACE" -l kubewarden/policy-server=user-ps \
        -o jsonpath='{.items[0].spec.template.spec.containers[0].env[?(@.name=="KUBEWARDEN_PORT")].value}')
    [[ "$kw_port" == "62100" ]]

    kw_readiness_port=$(kubectl get deployment -n "$NAMESPACE" -l kubewarden/policy-server=user-ps \
        -o jsonpath='{.items[0].spec.template.spec.containers[0].env[?(@.name=="KUBEWARDEN_READINESS_PROBE_PORT")].value}')
    [[ "$kw_readiness_port" == "62101" ]]

    # Verify the readiness probe targets the new port
    local probe_port
    probe_port=$(kubectl get deployment -n "$NAMESPACE" -l kubewarden/policy-server=user-ps \
        -o jsonpath='{.items[0].spec.template.spec.containers[0].readinessProbe.httpGet.port}')
    [[ "$probe_port" == "62101" ]]

    # Verify the PolicyServer Service targetPort changed to the new webhook port
    local svc_target_port
    svc_target_port=$(kubectl get svc -n "$NAMESPACE" policy-server-user-ps \
        -o jsonpath='{.spec.ports[?(@.name=="policy-server")].targetPort}')
    [[ "$svc_target_port" == "62100" ]]

    # Verify hostNetwork is still enabled after the port change
    assert_deployment_hostnetwork "kubewarden/policy-server=user-ps" "true"

    # Deploy a policy and verify evaluation works with the new ports
    apply_policy privileged-pod-policy.yaml

    kuberun --image=rancher/pause:3.2

    kubefail_privileged run pod-privileged-crd-ports --image=rancher/pause:3.2 --privileged

    delete_policy privileged-pod-policy.yaml
}


@test "$(tfile) Disable hostNetwork and change controller ports" {
    # Clean up second PolicyServer before disabling hostNetwork
    kubectl delete policyserver user-ps --wait
    wait_rollout deployment/policy-server-default

    # Disable hostNetwork AND change all controller ports in one upgrade.
    # All ports must change together to avoid bind conflicts during rollout.
    helmer set kubewarden-controller --set hostNetwork=false \
        --set ports.webhook=63200 \
        --set ports.healthProbe=63201 \
        --set ports.metrics=63202
    wait_rollout deployment/kubewarden-controller
    wait_policyserver default

    # Verify hostNetwork is disabled
    assert_deployment_hostnetwork "app.kubernetes.io/name=kubewarden-controller" "false"
    assert_deployment_hostnetwork "kubewarden/policy-server=default" "false"

    # Verify DNS policy reverted from ClusterFirstWithHostNet
    local policyserver_dns
    policyserver_dns=$(kubectl get deployment -n "$NAMESPACE" -l kubewarden/policy-server=default \
        -o jsonpath='{.items[0].spec.template.spec.dnsPolicy}')
    [[ "$policyserver_dns" != "ClusterFirstWithHostNet" ]]

    # Verify policy evaluation still works after disabling hostNetwork
    apply_policy privileged-pod-policy.yaml

    kuberun --image=rancher/pause:3.2

    kubefail_privileged run pod-privileged-disable --image=rancher/pause:3.2 --privileged

    delete_policy privileged-pod-policy.yaml
}
