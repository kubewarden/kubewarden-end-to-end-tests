#!/usr/bin/env bats

setup() {
	load common.bash
	wait_pods
}

teardown_file() {
	kubectl delete pods --all
	kubectl delete clusteradmissionpolicies --all
	kubectl delete -f $RESOURCES_DIR/policy-server.yaml --ignore-not-found
}

# Create pod-privileged policy to block CREATE & UPDATE of privileged pods
@test "[Basic end-to-end tests] Apply pod-privileged policy that blocks CREATE & UPDATE" {
	apply_cluster_admission_policy $RESOURCES_DIR/privileged-pod-policy.yaml

	# Launch unprivileged pod
	kubectl run nginx-unprivileged --image=nginx:alpine
	kubectl wait --for=condition=Ready pod nginx-unprivileged

	# Launch privileged pod (should fail)
	kubefail_privileged run pod-privileged --image=k8s.gcr.io/pause --privileged
}

# Update pod-privileged policy to block only UPDATE of privileged pods
@test  "[Basic end-to-end tests] Patch policy to block only UPDATE operation" {
        yq '.spec.rules[0].operations = ["UPDATE"]' resources/privileged-pod-policy.yaml | kubectl apply -f -

	# I can create privileged pods now
	kubectl run nginx-privileged --image=nginx:alpine --privileged

	# I can not update privileged pods
	kubefail_privileged label pod nginx-privileged x=y
}

@test "[Basic end-to-end tests] Delete ClusterAdmissionPolicy" {
	kubectl delete --wait -f $RESOURCES_DIR/privileged-pod-policy.yaml

	# I can update privileged pods now
	kubectl label pod nginx-privileged x=y
}

@test "[Basic end-to-end tests] Apply mutating psp-user-group ClusterAdmissionPolicy" {
	apply_cluster_admission_policy $RESOURCES_DIR/psp-user-group-policy.yaml

	# Policy should mutate pods
	kubectl run pause-user-group --image k8s.gcr.io/pause
	kubectl wait --for=condition=Ready pod pause-user-group
	kubectl get pods pause-user-group -o json | jq -e ".spec.containers[].securityContext.runAsUser==1000"

	kubectl delete --wait -f $RESOURCES_DIR/psp-user-group-policy.yaml
}

@test "[Basic end-to-end tests] Launch & scale second policy server" {
	kubectl apply -f $RESOURCES_DIR/policy-server.yaml
	kubectl wait policyserver e2e-tests --for=condition=ServiceReconciled

	kubectl patch policyserver e2e-tests --type=merge -p '{"spec": {"replicas": 2}}'
	wait_rollout -n kubewarden deployment/policy-server-e2e-tests

	kubectl delete -f $RESOURCES_DIR/policy-server.yaml
}
