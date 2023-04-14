#!/usr/bin/env bats

setup() {
	load common.bash
	wait_pods
}

teardown_file() {
	kubectl delete pods --all
	kubectl delete clusteradmissionpolicies --all
}

# Same as in basic e2e tests?
@test "[Context Aware Policy tests] Test mutating a Pod" {
	apply_cluster_admission_policy $RESOURCES_DIR/context-aware-policy.yaml

	# Create Pod with the right annotation
	kubectl create ns ctx-test
	kubectl annotate namespaces ctx-test propagate.hello=world

	kubectl run --namespace ctx-test pause-user-group --image registry.k8s.io/pause
	kubectl wait --for=condition=Ready pod --namespace ctx-test pause-user-group
	kubectl get pod --namespace ctx-test pause-user-group -o json | jq -e '.metadata.labels["hello"]=="world"'
	kubectl delete namespace ctx-test

	kubectl delete -f $RESOURCES_DIR/context-aware-policy.yaml
}
