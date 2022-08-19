#!/usr/bin/env bats

setup() {
	load common.bash
	wait_pods -n kubewarden
}

teardown_file() {
	kubectl delete pods --all
	kubectl delete clusteradmissionpolicies --all
}

@test "[Monitor mode end-to-end tests] Install ClusterAdmissionPolicy in monitor mode" {
	apply_cluster_admission_policy $RESOURCES_DIR/privileged-pod-policy-monitor.yaml
}

@test "[Monitor mode end-to-end tests] Monitor mode should only log event" {
	kubectl run nginx-privileged --image=nginx:alpine --privileged
	default_policy_server_should_have_log_line "policy evaluation (monitor mode)"
	default_policy_server_should_have_log_line "allowed: false"
	default_policy_server_should_have_log_line "cannot schedule privileged containers"
	kubectl delete pod nginx-privileged
}

@test "[Monitor mode end-to-end tests] Transition to protect should block events" {
	apply_cluster_admission_policy $RESOURCES_DIR/privileged-pod-policy.yaml

	# Launch privileged pod (should fail)
	kubefail_privileged run pod-privileged --image=k8s.gcr.io/pause --privileged
}

@test "[Monitor mode end-to-end tests] Transition from protect to monitor should be disallowed" {
	kubectl_apply_should_fail_with_message $RESOURCES_DIR/privileged-pod-policy-monitor.yaml "field cannot transition from protect to monitor. Recreate instead."
}
