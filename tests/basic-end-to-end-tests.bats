#!/usr/bin/env bats

source $BATS_TEST_DIRNAME/common.bash

setup_file() {
	kubectl --context $CLUSTER_CONTEXT delete --wait --ignore-not-found pods --all
	kubectl --context $CLUSTER_CONTEXT delete --wait --ignore-not-found -n kubewarden clusteradmissionpolicies --all
	kubectl --context $CLUSTER_CONTEXT wait --for=condition=Ready -n kubewarden pod --all
}

@test "[Basic end-to-end tests] Install ClusterAdmissionPolicy" {
	apply_cluster_admission_policy $RESOURCES_DIR/privileged-pod-policy.yaml
}

@test "[Basic end-to-end tests] Launch a privileged pod should fail" {
	kubectl_apply_should_fail $RESOURCES_DIR/violate-privileged-pod-policy.yaml
}

@test  "[Basic end-to-end tests] Launch a pod which does not violate privileged pod policy" {
	kubectl_apply_should_succeed $RESOURCES_DIR/not-violate-privileged-pod-policy.yaml
}

@test  "[Basic end-to-end tests] Update privileged pod policy to check only UPDATE operations" {
        run kubectl --context $CLUSTER_CONTEXT patch clusteradmissionpolicy privileged-pods --type=json --patch-file $RESOURCES_DIR/privileged-pod-policy-patch.json
	[ "$status" -eq 0 ]
}

@test "[Basic end-to-end tests] Launch a pod which violate privileged pod policy after policy change should work" {
	kubectl_apply_should_succeed $RESOURCES_DIR/violate-privileged-pod-policy.yaml
}

@test "[Basic end-to-end tests] Delete ClusterAdmissionPolicy" {
	kubectl_delete $RESOURCES_DIR/privileged-pod-policy.yaml
}

@test "[Basic end-to-end tests] Launch a pod which violate privileged pod policy after policy deletion should work" {
	kubectl_apply_should_succeed $RESOURCES_DIR/violate-privileged-pod-policy.yaml
}

@test "[Basic end-to-end tests] Install psp-user-group ClusterAdmissionPolicy" {
	apply_cluster_admission_policy $RESOURCES_DIR/psp-user-group-policy.yaml
}

@test "[Basic end-to-end tests] Launch a pod that should be mutate by psp-user-group-policy" {
	kubectl_apply_should_succeed $RESOURCES_DIR/mutate-pod-psp-user-group-policy.yaml
	run kubectl --context $CLUSTER_CONTEXT wait --for=condition=Ready pod pause-user-group
	run eval `kubectl --context $CLUSTER_CONTEXT get pod pause-user-group -o json | jq ".spec.containers[].securityContext.runAsUser==1000"`
	[ "$status" -eq 0 ]
}

@test "[Basic end-to-end tests] Launch second policy server" {
	kubectl_apply_should_succeed $RESOURCES_DIR/policy-server.yaml
}

@test "[Basic end-to-end tests] Update PolicyServer" {
	run kubectl --context $CLUSTER_CONTEXT patch policyserver default --type=merge -p '{"spec": {"replicas": 2}}'
	[ "$status" -eq 0 ]
}

@test "[Basic end-to-end tests] All PolicyServer pods should be ready" {
	wait_for_all_pods_to_be_ready
}

@test "[Basic end-to-end tests] Delete policy server" {
	kubectl_delete $RESOURCES_DIR/policy-server.yaml
}

@test "[Basic end-to-end tests] All PolicyServer pods should be ready after the delete operation" {
	wait_for_all_pods_to_be_ready
}
