#!/usr/bin/env bats

setup() {
	load common.bash
	wait_pods
}

teardown_file() {
	kubectl delete --wait --timeout $TIMEOUT --ignore-not-found clusteradmissionpolicies --all
	kubectl delete --wait --timeout $TIMEOUT --ignore-not-found -f $RESOURCES_DIR/violate-privileged-pod-policy.yaml
	kubectl delete --wait --timeout $TIMEOUT --ignore-not-found -f $RESOURCES_DIR/not-violate-privileged-pod-policy.yaml
}

@test "[Reconfiguration tests] Test apply policy" {
	apply_cluster_admission_policy $RESOURCES_DIR/privileged-pod-policy.yaml
}

@test "[Reconfiguration tests] Test apply pod which violate a policy" {
	kubectl_apply_should_fail $RESOURCES_DIR/violate-privileged-pod-policy.yaml
}

@test "[Reconfiguration tests] Test apply pod which does not violate a policy" {
	kubectl_apply $RESOURCES_DIR/not-violate-privileged-pod-policy.yaml
}

@test "[Reconfiguration tests] Reconfigure Kubewarden stack" {
	helm upgrade --wait --namespace $NAMESPACE --reuse-values  \
		--values=$RESOURCES_DIR/reconfiguration-values.yaml \
		$KUBEWARDEN_CONTROLLER_CHART_RELEASE $CONTROLLER_CHART
	wait_for_cluster_admission_policy PolicyActive
}

@test "[Reconfiguration tests] Install psp-user-group ClusterAdmissionPolicy after reconfiguration" {
	apply_cluster_admission_policy $RESOURCES_DIR/psp-user-group-policy.yaml
}

@test "[Reconfiguration tests] Test apply pod which violate a policy after reconfiguration" {
	kubectl_delete $RESOURCES_DIR/violate-privileged-pod-policy.yaml
	kubectl_apply_should_fail $RESOURCES_DIR/violate-privileged-pod-policy.yaml
}

@test "[Reconfiguration tests] Test apply pod which does not violate a policy after reconfiguration" {
	kubectl_delete $RESOURCES_DIR/not-violate-privileged-pod-policy.yaml
	kubectl_apply $RESOURCES_DIR/not-violate-privileged-pod-policy.yaml
}

