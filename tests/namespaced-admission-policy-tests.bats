#!/usr/bin/env bats

setup() {
	load common.bash
	wait_pods
}

teardown_file() {
	kubectl delete --wait --ignore-not-found pods --all
	kubectl delete --wait --ignore-not-found -n kubewarden clusteradmissionpolicies --all
	kubectl delete --wait --ignore-not-found -n kubewarden admissionpolicies --all
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
	kubectl_apply $RESOURCES_DIR/not-violate-privileged-pod-policy.yaml
}

@test  "[AdmissionPolicy tests] Update privileged pod policy to check only UPDATE operations" {
        kubectl patch admissionpolicy privileged-pods --type=json -p ' [{ "op": "remove", "path": "/spec/rules/0/operations/1" }, { "op": "replace", "path": "/spec/rules/0/operations/0", "value": "UPDATE" } ]'
}

@test "[AdmissionPolicy tests] Launch a pod which violate privileged pod policy after policy change should work" {
	kubectl_apply $RESOURCES_DIR/violate-privileged-pod-policy.yaml
}

@test "[AdmissionPolicy tests] Delete AdmissionPolicy" {
	kubectl_delete $RESOURCES_DIR/namespaced-privileged-pod-policy.yaml
}

@test "[AdmissionPolicy tests] Launch a pod which violate privileged pod policy after policy deletion should work" {
	kubectl_apply $RESOURCES_DIR/violate-privileged-pod-policy.yaml
}
