#!/usr/bin/env bats

setup() {
	load common.bash
	wait_pods
}

teardown_file() {
	kubectl delete --wait --ignore-not-found pods --all
	kubectl delete --wait --ignore-not-found clusteradmissionpolicies --all
}

@test "[Monitor mode end-to-end tests] Install ClusterAdmissionPolicy in monitor mode" {
	apply_cluster_admission_policy $RESOURCES_DIR/privileged-pod-policy-monitor.yaml
}

@test "[Monitor mode end-to-end tests] Launch a privileged pod should succeed" {
	kubectl apply -f $RESOURCES_DIR/violate-privileged-pod-policy.yaml
	default_policy_server_should_have_log_line "policy evaluation (monitor mode)"
	default_policy_server_should_have_log_line "allowed: false"
	default_policy_server_should_have_log_line "cannot schedule privileged containers"
	kubectl_delete $RESOURCES_DIR/violate-privileged-pod-policy.yaml
}

@test "[Monitor mode end-to-end tests] Transition policy mode from monitor to protect should succeed" {
	apply_cluster_admission_policy $RESOURCES_DIR/privileged-pod-policy.yaml
}

@test "[Monitor mode end-to-end tests] Launch a privileged pod should fail" {
	kubectl_apply_should_fail_with_message $RESOURCES_DIR/violate-privileged-pod-policy.yaml "cannot schedule privileged containers"
}

@test "[Monitor mode end-to-end tests] Transition policy mode from protect to monitor should be disallowed" {
	kubectl_apply_should_fail_with_message $RESOURCES_DIR/privileged-pod-policy-monitor.yaml "field cannot transition from protect to monitor. Recreate instead."
}
