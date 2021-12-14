#!/usr/bin/env bats

setup_file() {
	kubectl delete --wait --ignore-not-found pods --all
	kubectl delete --wait --ignore-not-found -n kubewarden clusteradmissionpolicies --all
	kubectl wait --for=condition=Ready -n kubewarden pod --all
}

@test "Install ClusterAdimissionPolicy" {
	run kubectl apply -f $RESOURCES_DIR/privileged-pod-policy.yaml
	run kubectl wait --for=condition=PolicyActive clusteradmissionpolicies --all
	[ "$status" -eq 0 ]
}

@test "Launch a privileged pod should fail" {
	run kubectl apply -f $RESOURCES_DIR/violate-privileged-pod-policy.yaml
	[ "$status" -ne 0 ]
}

@test  "Launch a pod which does not violate privileged pod policy" {
        run kubectl apply -f $RESOURCES_DIR/not-violate-privileged-pod-policy.yaml
	[ "$status" -eq 0 ]
}

@test  "Update privileged pod policy to check only UPDATE operations" {
        run kubectl patch clusteradmissionpolicy privileged-pods --type=json --patch-file $RESOURCES_DIR/privileged-pod-policy-patch.json
	[ "$status" -eq 0 ]
}

@test "Launch a pod which violate privileged pod policy after policy change should work" {
	run kubectl apply -f $RESOURCES_DIR/violate-privileged-pod-policy.yaml
	[ "$status" -eq 0 ]
}

@test "Delete ClusterAdmissionPolicy" {
	run kubectl delete --wait --timeout=2m -f $RESOURCES_DIR/privileged-pod-policy.yaml
	[ "$status" -eq 0 ]
}

@test "Launch a pod which violate privileged pod policy after policy deletion should work" {
	run kubectl apply -f $RESOURCES_DIR/violate-privileged-pod-policy.yaml
	[ "$status" -eq 0 ]
}

@test "Install psp-user-group ClusterAdmissionPolicy" {
	run kubectl apply -f $RESOURCES_DIR/psp-user-group-policy.yaml
	run kubectl wait --timeout=2m --for=condition=PolicyActive clusteradmissionpolicies --all
	[ "$status" -eq 0 ]
}

@test "Launch a pod that should be mutate by psp-user-group-policy" {
	run kubectl apply -f $RESOURCES_DIR/mutate-pod-psp-user-group-policy.yaml
	run kubectl wait --for=condition=Ready pod pause-user-group
	run eval `kubectl get pod pause-user-group -o json | jq ".spec.containers[].securityContext.runAsUser==1000"`
	[ "$status" -eq 0 ]
}

@test "Launch second policy server" {
	run kubectl apply -f $RESOURCES_DIR/policy-server.yaml
	[ "$status" -eq 0 ]
}

@test "Update PolicyServer" {
	run kubectl patch policyserver default --type=merge -p '{"spec": {"replicas": 2}}'
	[ "$status" -eq 0 ]
}

@test "All PolicyServer pods should be ready" {
	run kubectl wait --for=condition=Ready -n kubewarden pod --all
	[ "$status" -eq 0 ]
}

@test "Delete policy server" {
	run kubectl delete --wait --timeout=5m -f $RESOURCES_DIR/policy-server.yaml
	[ "$status" -eq 0 ]
}

@test "All PolicyServer pods should be ready after the delete operation" {
	run kubectl wait --for=condition=Ready -n kubewarden pod --all
	[ "$status" -eq 0 ]
}
