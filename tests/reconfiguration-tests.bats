#!/usr/bin/env bats

source $BATS_TEST_DIRNAME/common.bash

setup_file() {
	run kubectl --context $CLUSTER_CONTEXT delete --wait --timeout $TIMEOUT --ignore-not-found clusteradmissionpolicies --all
	run kubectl --context $CLUSTER_CONTEXT delete --wait --timeout $TIMEOUT --ignore-not-found -f $RESOURCES_DIR/violate-privileged-pod-policy.yaml
	run kubectl --context $CLUSTER_CONTEXT delete --wait --timeout $TIMEOUT --ignore-not-found -f $RESOURCES_DIR/not-violate-privileged-pod-policy.yaml
	run kubectl --context $CLUSTER_CONTEXT wait --timeout $TIMEOUT --for=condition=Ready --namespace $NAMESPACE pods --all
}

@test "[Reconfiguration tests] Test apply policy" {
	apply_cluster_admission_policy $RESOURCES_DIR/privileged-pod-policy.yaml
}

@test "[Reconfiguration tests] Test apply pod which violate a policy" {
	kubectl_apply_should_fail  $RESOURCES_DIR/violate-privileged-pod-policy.yaml
}

@test "[Reconfiguration tests] Test apply pod which does not violate a policy" {
	kubectl_apply_should_succeed $RESOURCES_DIR/not-violate-privileged-pod-policy.yaml
}

@test "[Reconfiguration tests] Reconfigure Kubewarden stack" {
	run helm upgrade --wait --namespace $NAMESPACE --reuse-values  \
		--kube-context $CLUSTER_CONTEXT \
		--values=$RESOURCES_DIR/reconfiguration-values.yaml \
		$KUBEWARDEN_CONTROLLER_CHART_RELEASE $CONTROLLER_CHART
	[ "$status" -eq 0 ]
	wait_for_all_cluster_admission_policies_to_be_active
}

@test "[Reconfiguration tests] Install psp-user-group ClusterAdmissionPolicy after reconfiguration" {
	apply_cluster_admission_policy $RESOURCES_DIR/psp-user-group-policy.yaml
}

@test "[Reconfiguration tests] Test apply pod which violate a policy after reconfiguration" {
	kubectl_delete  $RESOURCES_DIR/violate-privileged-pod-policy.yaml
	kubectl_apply_should_fail   $RESOURCES_DIR/violate-privileged-pod-policy.yaml
}

@test "[Reconfiguration tests] Test apply pod which does not violate a policy after reconfiguration" {
	kubectl_delete  $RESOURCES_DIR/not-violate-privileged-pod-policy.yaml
	kubectl_apply_should_succeed  $RESOURCES_DIR/not-violate-privileged-pod-policy.yaml
}

