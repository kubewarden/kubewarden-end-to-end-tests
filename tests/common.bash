#!/bin/bash

function kubectl_apply_should_fail {
	run kubectl --context $CLUSTER_CONTEXT apply --wait --timeout $TIMEOUT  -f $1
	[ "$status" -ne 0 ]
}

function kubectl_apply_should_fail_with_message {
	kubectl_apply_should_fail $1
	if [[ $output != *"$2"* ]]; then
		echo "Missing string in the output:"
		echo "Output: $output"
		echo "Missing string: $2"
		fail
	fi
}

function kubectl_apply_should_succeed {
	run kubectl --context $CLUSTER_CONTEXT apply --wait --timeout $TIMEOUT  -f $1
	[ "$status" -eq 0 ]
}

function apply_cluster_admission_policy {
	kubectl_apply_should_succeed $1
	wait_for_all_cluster_admission_policies_to_be_active
	wait_for_default_policy_server_rollout
	wait_for_all_cluster_admission_policy_condition PolicyUniquelyReachable
}

function apply_admission_policy {
	kubectl_apply_should_succeed $1
	wait_for_all_admission_policies_to_be_active
	wait_for_default_policy_server_rollout
	wait_for_all_admission_policy_condition PolicyUniquelyReachable
}

function kubectl_delete {
	run kubectl --context $CLUSTER_CONTEXT  delete --wait --timeout $TIMEOUT --ignore-not-found -f $1
	[ "$status" -eq 0 ]
}

function wait_for_all_cluster_admission_policies_to_be_active {
	wait_for_all_cluster_admission_policy_condition PolicyActive
}

function wait_for_all_cluster_admission_policy_condition {
	run kubectl --context $CLUSTER_CONTEXT wait --timeout $TIMEOUT --for=condition="$1" clusteradmissionpolicies --all
	[ "$status" -eq 0 ]
}

function wait_for_all_admission_policies_to_be_active {
	run kubectl --context $CLUSTER_CONTEXT wait --timeout $TIMEOUT --for=condition=PolicyActive admissionpolicies -A --all
	[ "$status" -eq 0 ]
}

function wait_for_all_admission_policy_condition {
	run kubectl --context $CLUSTER_CONTEXT wait --timeout $TIMEOUT --for=condition="$1" admissionpolicies -A --all
	[ "$status" -eq 0 ]
}

function wait_for_all_pods_to_be_ready {
	wait_for_default_policy_server_rollout
	run kubectl --context $CLUSTER_CONTEXT wait --for=condition=Ready --timeout $TIMEOUT -n kubewarden pod --all
	[ "$status" -eq 0 ]
}

function wait_for_default_policy_server_rollout {
	wait_for_policy_server_rollout default
}

function wait_for_policy_server_rollout {
	run kubectl --context $CLUSTER_CONTEXT -n $NAMESPACE rollout status "deployment/policy-server-$1"
}

function default_policy_server_should_have_log_line {
	policy_server_should_have_log_line default "$1"
}

function policy_server_should_have_log_line {
	run kubectl --context $CLUSTER_CONTEXT logs -n $NAMESPACE -lapp="kubewarden-policy-server-$1" | grep "$2"
}
