#!/usr/bin/env bash

bats_require_minimum_version 1.7.0

load "../helpers/bats-support/load.bash"
load "../helpers/bats-assert/load.bash"

function kubectl() {
	command kubectl --context $CLUSTER_CONTEXT "$@"
}

function helm() {
	command helm --kube-context $CLUSTER_CONTEXT "$@"
}

function helm_in {
    helm upgrade --install --wait --namespace $NAMESPACE --create-namespace \
        "${@:2}" $1 $KUBEWARDEN_CHARTS_LOCATION/$1

    # kubewarden-defaults ignore wait param, so rollout status would fail without retry (does not exist yet)
    # retry function requires full command, not a function
    [ $1 = 'kubewarden-defaults' ] && retry "kubectl --context $CLUSTER_CONTEXT rollout status -n kubewarden deployment/policy-server-default"
    return 0
}

function helm_rm {
    helm uninstall --wait --namespace $NAMESPACE $1
}

function helm_up {
    helm upgrade --wait --namespace $NAMESPACE "${@:2}" $1 $KUBEWARDEN_CHARTS_LOCATION/$1
}

function retry() {
    local cmd=$1
    local tries=${2:-10}
    local delay=${3:-30}
    local i
    for ((i=1; i<=tries; i++)); do
        timeout 25 bash -c "$cmd" && break || echo "RETRY #$i: $cmd"
        [ $i -ne $tries ] && sleep $delay || { echo "Godot: $cmd"; false; }
    done
}

# Safe version of waiting for pods. Looks in kube-system ns by default
# Handles kube-api disconnects during upgrade
function wait_pods() {
    local i output
    for i in {1..20}; do
        output=$(kubectl get pods --no-headers -o wide ${@:--n kubewarden} | grep -vw Completed || echo 'Fail')
        grep -vE '([0-9]+)/\1 +Running' <<< $output || break
        [ $i -ne 20 ] && sleep 30 || { echo "Godot: pods not running"; false; }
    done
}

# Safe version of waiting for nodes
# Handles kube-api disconnects during upgrade
function wait_nodes() {
    local i output
    for i in {1..20}; do
        output=$(kubectl get nodes --no-headers ${@:-} || echo 'Fail')
        grep -vE '\bReady\b' <<< $output || break
        [ $i -ne 20 ] && sleep 30 || { echo "Godot: nodes not running"; false; }
    done
}

function wait_for    () { kubectl wait --timeout=5m "$@"; }
function wait_rollout() { kubectl rollout status --timeout=5m "$@"; }

# Wait for cluster to come up after reboot
function wait_cluster() {
    retry "kubectl cluster-info" 20 30
    wait_nodes
    wait_pods
}

# Run kubectl action which should fail on pod privileged policy
function kubefail_privileged {
	run kubectl "$@"
	assert_failure 1
	assert_output --regexp '^Error.*: admission webhook.*denied the request.*container is not allowed$'
}

function kubectl_apply_should_fail {
	run kubectl apply -f $1
	assert_failure
}

function kubectl_apply_should_fail_with_message {
	run kubectl apply -f $1
	assert_failure
	assert_output --partial "$2"
}

function apply_cluster_admission_policy {
	kubectl apply -f $1
	wait_for_cluster_admission_policy PolicyActive
	wait_for_default_policy_server_rollout
	wait_for_cluster_admission_policy PolicyUniquelyReachable
}

function apply_admission_policy {
	kubectl apply -f ${1:--}
	wait_for_admission_policy PolicyActive
	wait_for_default_policy_server_rollout
	wait_for_admission_policy PolicyUniquelyReachable
}

function wait_for_admission_policy {
	wait_for --for=condition="$1" admissionpolicies --all -A
}

function wait_for_cluster_admission_policy {
	wait_for --for=condition="$1" clusteradmissionpolicies --all
}

function wait_for_default_policy_server_rollout {
	revision=$(kubectl -n $NAMESPACE get "deployment/policy-server-default" -o json | jq -r '.metadata.annotations."deployment.kubernetes.io/revision"')
	wait_rollout -n $NAMESPACE --revision $revision "deployment/policy-server-default"
}
