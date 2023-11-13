#!/usr/bin/env bats

setup() {
	load common.bash
	wait_pods
}

teardown_file() {
	kubectl delete pods --all
	kubectl delete admissionpolicies --all -A
	kubectl delete clusteradmissionpolicies --all
}

@test "[Reconfiguration tests] Apply pod-privileged policy" {
	apply_cluster_admission_policy $RESOURCES_DIR/privileged-pod-policy.yaml
}

@test "[Reconfiguration tests] Reconfigure Kubewarden stack" {
	helm_up kubewarden-controller --values=$RESOURCES_DIR/reconfiguration-values.yaml
	wait_for_cluster_admission_policy PolicyActive
}

@test "[Reconfiguration tests] Apply psp-user-group policy" {
	apply_cluster_admission_policy $RESOURCES_DIR/psp-user-group-policy.yaml
}

@test "[Reconfiguration tests] Test that pod-privileged policy works" {
	# Launch unprivileged pod
	kubectl run pause-unprivileged --image registry.k8s.io/pause
	kubectl wait --for=condition=Ready pod pause-unprivileged

	# Launch privileged pod (should fail)
	kubefail_privileged run pause-privileged --image registry.k8s.io/pause --privileged
}
