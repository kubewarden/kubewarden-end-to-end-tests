#!/bin/bash

function clean_up_environment {
	kubectl --context $CLUSTER_CONTEXT delete --wait --ignore-not-found pods --all
	kubectl --context $CLUSTER_CONTEXT delete --wait --ignore-not-found -n kubewarden clusteradmissionpolicies --all
	kubectl --context $CLUSTER_CONTEXT delete --wait --ignore-not-found -n kubewarden admissionpolicies --all
	kubectl --context $CLUSTER_CONTEXT wait --for=condition=Ready -n kubewarden pod --all
}

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

function kubectl_delete_by_type_and_name {
	run kubectl --context $CLUSTER_CONTEXT -n $NAMESPACE delete --wait --timeout $TIMEOUT  --ignore-not-found $1 $2
	[ "$status" -eq 0 ]
}

function kubectl_delete_configmap_by_name {
	kubectl_delete_by_type_and_name configmap $1
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

function default_policy_server_rollout_should_fail {
	revision=$(kubectl --context $CLUSTER_CONTEXT -n $NAMESPACE get "deployment/policy-server-default" -o json | jq ".metadata.annotations.\"deployment.kubernetes.io/revision\"" | sed "s/\"//g")
	run kubectl --context $CLUSTER_CONTEXT -n $NAMESPACE rollout status --revision $revision --timeout $TIMEOUT "deployment/policy-server-default"
	[ "$status" -ne 0 ]
}

function wait_for_policy_server_rollout {
	revision=$(kubectl --context $CLUSTER_CONTEXT -n $NAMESPACE get "deployment/policy-server-$1" -o json | jq ".metadata.annotations.\"deployment.kubernetes.io/revision\"" | sed "s/\"//g")
	run kubectl --context $CLUSTER_CONTEXT -n $NAMESPACE rollout status --revision $revision "deployment/policy-server-$1"
}

function default_policy_server_should_have_log_line {
	policy_server_should_have_log_line default "$1"
}

function policy_server_should_have_log_line {
	run kubectl --context $CLUSTER_CONTEXT logs -n $NAMESPACE -lapp="kubewarden-policy-server-$1" | grep "$2"
}

function create_configmap_from_file_with_root_key {
	run kubectl --context $CLUSTER_CONTEXT -n $NAMESPACE create configmap $1 --from-file=$2=$3
}

function kubewarden_crds_should_not_be_installed {
	run kubectl --context $CLUSTER_CONTEXT get crds policyservers.policies.kubewarden.io clusteradmissionpolicies.policies.kubewarden.io admissionpolicies.policies.kubewarden.io
}


function install_kubewarden_stack {
	run helm install --kube-context $CLUSTER_CONTEXT --wait -n kubewarden --create-namespace kubewarden-crds kubewarden/kubewarden-crds
	run helm install --kube-context $CLUSTER_CONTEXT --wait -n kubewarden kubewarden-controller kubewarden/kubewarden-controller
	run helm install --kube-context $CLUSTER_CONTEXT --wait -n kubewarden kubewarden-defaults kubewarden/kubewarden-defaults
} 
