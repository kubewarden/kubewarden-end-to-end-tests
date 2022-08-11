#!/usr/bin/env bats

setup() {
	load common.bash
	wait_pods -n kubewarden
}

teardown_file() {
	kubectl delete pods --all
	kubectl delete clusteradmissionpolicies --all
}

@test "[Reconfiguration tests] Apply pod-privileged policy" {
	apply_cluster_admission_policy $RESOURCES_DIR/privileged-pod-policy.yaml
}

@test "[Reconfiguration tests] Reconfigure Kubewarden stack" {
	helm upgrade --wait --namespace $NAMESPACE --reuse-values  \
		--values=$RESOURCES_DIR/reconfiguration-values.yaml \
		$KUBEWARDEN_CONTROLLER_CHART_RELEASE $CONTROLLER_CHART
	wait_for_cluster_admission_policy PolicyActive
}

@test "[Reconfiguration tests] Apply psp-user-group policy" {
	apply_cluster_admission_policy $RESOURCES_DIR/psp-user-group-policy.yaml
}

@test "[Reconfiguration tests] Test that pod-privileged policy works" {
	# Launch unprivileged pod
	kubectl run pause-unprivileged --image k8s.gcr.io/pause
	kubectl wait --for=condition=Ready pod pause-unprivileged

	# Launch privileged pod (should fail)
	run kubectl run pause-privileged --image k8s.gcr.io/pause --privileged
	assert_failure
	assert_output --regexp '^Error.*: admission webhook.*denied the request.*cannot schedule privileged containers$'
	run ! kubectl get pods pause-privileged
}
