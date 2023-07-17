#!/usr/bin/env bats

setup() {
  load common.bash
  wait_pods -n kube-system
}

@test "[Audit Scanner] Install testing policies and resources" {
	run kubectl get cronjob -A
	assert_output -p audit-scanner

	# Launch unprivileged pod
	kubectl run nginx-unprivileged --image=nginx:alpine
	kubectl wait --for=condition=Ready pod nginx-unprivileged

	# Launch privileged pod
	kubectl run nginx-privileged --image=registry.k8s.io/pause --privileged
	kubectl wait --for=condition=Ready pod nginx-privileged

	# Deploy some policy
	apply_cluster_admission_policy $RESOURCES_DIR/privileged-pod-policy.yaml
	apply_cluster_admission_policy $RESOURCES_DIR/namespace-label-propagator-policy.yaml

}

@test "[Audit Scanner] Trigger audit scanner job" {
    run kubectl get jobs -A
    refute_output -p 'testing'

    run kubectl create job  --from=cronjob/audit-scanner testing  --namespace $NAMESPACE
    assert_output -p "testing created"
}

@test "[Audit Scanner] Check cluster wide report results" {
    retry "kubectl get clusterpolicyreports -o json | jq -e '[.items[].metadata.name == \"polr-clusterwide\"] | any'"
    retry "kubectl get clusterpolicyreports polr-clusterwide -o json | jq -e '[.summary.pass == 6] | all'" #1
    retry "kubectl get clusterpolicyreports polr-clusterwide -o json | jq -e '[.results[] | select(.resources[0].name==\"default\") | .result==\"pass\"] | all'"
}

@test "[Audit Scanner] Check namespaced report results" {
    retry "kubectl get policyreports -o json | jq -e '[.items[].metadata.name == \"polr-ns-default\"] | any'"
    retry "kubectl get policyreports polr-ns-default -o json | jq -e '[.summary.fail == 1] | all'"
    retry "kubectl get policyreports polr-ns-default -o json | jq -e '[.summary.pass == 1] | all'"

    retry "kubectl get policyreports polr-ns-default -o json | jq -e '[.results[] | select(.resources[0].name==\"nginx-unprivileged\") | .result==\"pass\"] | all'"
    retry "kubectl get policyreports polr-ns-default -o json | jq -e '[.results[] | select(.resources[0].name==\"nginx-privileged\") | .result==\"fail\"] | all'"
}
