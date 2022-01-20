#!/usr/bin/env bats

source $BATS_TEST_DIRNAME/common.bash

setup_file() {
	kubectl --context $CLUSTER_CONTEXT delete --wait --ignore-not-found pods --all
	kubectl --context $CLUSTER_CONTEXT delete --wait --ignore-not-found -n kubewarden clusteradmissionpolicies --all
	kubectl --context $CLUSTER_CONTEXT wait --for=condition=Ready -n kubewarden pod --all
}

@test "[Mutation request tests] Install mutate policy with mutating flag enabled" {
	apply_cluster_admission_policy $RESOURCES_DIR/mutate-policy-with-flag-enabled.yaml
}

@test "[Mutation request tests] Launch a pod that should be mutate by psp-user-group-policy" {
	kubectl_apply_should_succeed $RESOURCES_DIR/mutate-pod-psp-user-group-policy.yaml
	run kubectl --context $CLUSTER_CONTEXT wait --for=condition=Ready pod pause-user-group
	run eval `kubectl --context $CLUSTER_CONTEXT get pod pause-user-group -o json | jq ".spec.containers[].securityContext.runAsUser==1000"`
	[ "$status" -eq 0 ]
}

@test "[Mutation request tests] Install mutate policy with mutating flag disabled" {
	kubectl_delete $RESOURCES_DIR/mutate-policy-with-flag-enabled.yaml
	apply_cluster_admission_policy $RESOURCES_DIR/mutate-policy-with-flag-disabled.yaml
}

@test "[Mutation request tests] Launch a pod that should be reject by psp-user-group-policy" {
	kubectl_delete $RESOURCES_DIR/mutate-pod-psp-user-group-policy.yaml
	kubectl_apply_should_fail_with_message $RESOURCES_DIR/mutate-pod-psp-user-group-policy.yaml "The policy attempted to mutate the request, but it is currently configured to not allow mutations"
}
