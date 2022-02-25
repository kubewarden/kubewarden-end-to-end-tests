#!/usr/bin/env bats

source $BATS_TEST_DIRNAME/common.bash

setup_file() {
	kubectl --context $CLUSTER_CONTEXT delete --wait --ignore-not-found pods --all
	kubectl --context $CLUSTER_CONTEXT delete --wait --ignore-not-found -n kubewarden admissionpolicies --all
	kubectl --context $CLUSTER_CONTEXT wait --for=condition=Ready -n kubewarden pod --all
}

@test "[AdmissionPolicy end-to-end tests] Install AdmissionPolicy" {
	apply_admission_policy $RESOURCES_DIR/namespaced-privileged-pod-policy.yaml
}

@test "[AdmissionPolicy tests] Launch a privileged pod in the default namespace should fail" {
	kubectl_apply_should_fail $RESOURCES_DIR/violate-privileged-pod-policy.yaml
}

@test "[AdmissionPolicy tests] Launch a privileged pod in the kubewarden namespace should work" {
	kubectl_apply_should_fail $RESOURCES_DIR/violate-privileged-pod-policy.yaml -n kubewarden
}

@test  "[AdmissionPolicy tests] Launch a pod which does not violate privileged pod policy" {
	kubectl_apply_should_succeed $RESOURCES_DIR/not-violate-privileged-pod-policy.yaml
}

@test  "[AdmissionPolicy tests] Update privileged pod policy to check only UPDATE operations" {
        run kubectl --context $CLUSTER_CONTEXT patch admissionpolicy privileged-pods --type=json -p ' [{ "op": "remove", "path": "/spec/rules/0/operations/1" }, { "op": "replace", "path": "/spec/rules/0/operations/0", "value": "UPDATE" } ]'
        run kubectl --context $CLUSTER_CONTEXT wait --timeout $TIMEOUT --for=condition=PolicyActive admissionpolicies --all
	[ "$status" -eq 0 ]
}

@test "[AdmissionPolicy tests] Launch a pod which violate privileged pod policy after policy change should work" {
	kubectl_apply_should_succeed $RESOURCES_DIR/violate-privileged-pod-policy.yaml
}

@test "[AdmissionPolicy tests] Delete AdmissionPolicy" {
	kubectl_delete $RESOURCES_DIR/namespaced-privileged-pod-policy.yaml
}

@test "[AdmissionPolicy tests] Launch a pod which violate privileged pod policy after policy deletion should work" {
	kubectl_apply_should_succeed $RESOURCES_DIR/violate-privileged-pod-policy.yaml
}
