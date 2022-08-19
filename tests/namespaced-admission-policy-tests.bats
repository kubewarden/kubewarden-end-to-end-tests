#!/usr/bin/env bats

setup() {
	load common.bash
	wait_pods -n kubewarden
}

teardown_file() {
	kubectl delete pods --all
	kubectl delete -f $RESOURCES_DIR/namespaced-privileged-pod-policy.yaml
}

@test "[Namespaced AdmissionPolicy] Test AdmissionPolicy in default NS" {
	apply_admission_policy $RESOURCES_DIR/namespaced-privileged-pod-policy.yaml

	# Privileged pod in the default namespace (should fail)
	kubefail_privileged run nginx-privileged --image=nginx:alpine --privileged

	# Privileged pod in the kubewarden namespace (should work)
	kubectl run nginx-privileged --image=nginx:alpine --privileged -n kubewarden
	kubectl wait --for=condition=Ready pod nginx-privileged -n kubewarden
	kubectl delete pod nginx-privileged -n kubewarden

	# Unprivileged pod in default namespace (should work)
	kubectl run nginx-unprivileged --image=nginx:alpine
	kubectl wait --for=condition=Ready pod nginx-unprivileged
	kubectl delete pod nginx-unprivileged
}

@test  "[Namespaced AdmissionPolicy] Update policy to check only UPDATE operations" {
	yq '.spec.rules[0].operations = ["UPDATE"]' resources/namespaced-privileged-pod-policy.yaml | kubectl apply -f -

	# I can create privileged pods now
	kubectl run nginx-privileged --image=nginx:alpine --privileged

	# I still can not update privileged pods
	kubefail_privileged label pod nginx-privileged x=y
	kubectl delete pod nginx-privileged
}

@test "[Namespaced AdmissionPolicy] Delete AdmissionPolicy to check restrictions are removed" {
	kubectl delete -f $RESOURCES_DIR/namespaced-privileged-pod-policy.yaml

	# I can create privileged pods
	kubectl run nginx-privileged --image=nginx:alpine --privileged

	# I can update privileged pods
	kubectl label pod nginx-privileged x=y
}
