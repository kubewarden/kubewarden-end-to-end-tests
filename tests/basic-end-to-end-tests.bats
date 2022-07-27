#!/usr/bin/env bats

setup() {
	load common.bash
	wait_pods
}

teardown_file() {
	kubectl delete --wait --ignore-not-found pods --all
	kubectl delete --wait --ignore-not-found -n kubewarden clusteradmissionpolicies --all
}

@test "[Basic end-to-end tests] Install ClusterAdmissionPolicy" {
	apply_cluster_admission_policy $RESOURCES_DIR/privileged-pod-policy.yaml
}

@test "[Basic end-to-end tests] Launch a privileged pod should fail" {
	kubectl_apply_should_fail $RESOURCES_DIR/violate-privileged-pod-policy.yaml
}

@test  "[Basic end-to-end tests] Launch a pod which does not violate privileged pod policy" {
	kubectl_apply $RESOURCES_DIR/not-violate-privileged-pod-policy.yaml
}

@test  "[Basic end-to-end tests] Update privileged pod policy to check only UPDATE operations" {
        kubectl patch clusteradmissionpolicy privileged-pods --type=json -p ' [{ "op": "remove", "path": "/spec/rules/0/operations/1" }, { "op": "replace", "path": "/spec/rules/0/operations/0", "value": "UPDATE" } ]'
}

@test "[Basic end-to-end tests] Launch a pod which violate privileged pod policy after policy change should work" {
	kubectl_apply $RESOURCES_DIR/violate-privileged-pod-policy.yaml
}

@test "[Basic end-to-end tests] Delete ClusterAdmissionPolicy" {
	kubectl_delete $RESOURCES_DIR/privileged-pod-policy.yaml
}

@test "[Basic end-to-end tests] Launch a pod which violate privileged pod policy after policy deletion should work" {
	kubectl_apply $RESOURCES_DIR/violate-privileged-pod-policy.yaml
}

@test "[Basic end-to-end tests] Install psp-user-group ClusterAdmissionPolicy" {
	apply_cluster_admission_policy $RESOURCES_DIR/psp-user-group-policy.yaml
}

@test "[Basic end-to-end tests] Launch a pod that should be mutate by psp-user-group-policy" {
	kubectl_apply $RESOURCES_DIR/mutate-pod-psp-user-group-policy.yaml
	kubectl wait --for=condition=Ready pod pause-user-group
	kubectl get pod pause-user-group -o json | jq -e ".spec.containers[].securityContext.runAsUser==1000"
}

@test "[Basic end-to-end tests] Launch second policy server" {
	kubectl_apply $RESOURCES_DIR/policy-server.yaml
}

@test "[Basic end-to-end tests] Scale up PolicyServer" {
	kubectl patch policyserver default --type=merge -p '{"spec": {"replicas": 2}}'
	wait_for_default_policy_server_rollout
}

@test "[Basic end-to-end tests] Delete policy server" {
	kubectl_delete $RESOURCES_DIR/policy-server.yaml
	wait_for_default_policy_server_rollout
}
