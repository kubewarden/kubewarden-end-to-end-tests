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
@test "[Mutation request tests] Test psp-user-group policy with mutating flag enabled" {
	apply_cluster_admission_policy $RESOURCES_DIR/mutate-policy-with-flag-enabled.yaml

	# New pod should be mutated by the policy
	kubectl run pause-user-group --image registry.k8s.io/pause
	kubectl wait --for=condition=Ready pod pause-user-group
	kubectl get pod pause-user-group -o json | jq -e ".spec.containers[].securityContext.runAsUser==1000"
	kubectl delete pod pause-user-group

	kubectl delete -f $RESOURCES_DIR/mutate-policy-with-flag-enabled.yaml
}

@test "[Mutation request tests] Test psp-user-group policy with mutating flag disabled" {
	apply_cluster_admission_policy $RESOURCES_DIR/mutate-policy-with-flag-disabled.yaml

	# New pod should be rejected by psp-user-group-policy
	run kubectl run pause-user-group --image registry.k8s.io/pause
	assert_failure
	assert_output --partial "The policy attempted to mutate the request, but it is currently configured to not allow mutations"

	kubectl delete -f $RESOURCES_DIR/mutate-policy-with-flag-disabled.yaml
}
