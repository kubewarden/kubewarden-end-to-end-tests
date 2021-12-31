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
}

function kubectl_delete {
	run kubectl --context $CLUSTER_CONTEXT  delete --wait --timeout $TIMEOUT --ignore-not-found -f $1
	[ "$status" -eq 0 ]
}

function wait_for_all_cluster_admission_policies_to_be_active {
	run kubectl --context $CLUSTER_CONTEXT wait --timeout $TIMEOUT --for=condition=PolicyActive clusteradmissionpolicies --all
	[ "$status" -eq 0 ]
}

function wait_for_all_pods_to_be_ready {
	run kubectl --context $CLUSTER_CONTEXT wait --for=condition=Ready -n kubewarden pod --all
	[ "$status" -eq 0 ]
}
