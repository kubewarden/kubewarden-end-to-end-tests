#!/usr/bin/env bats

setup() {
	load common.bash
	wait_pods
}

teardown_file() {
	kubectl delete --ignore-not-found -f $RESOURCES_DIR/privileged-pod-policy.yaml
	kubectl delete --ignore-not-found -f $RESOURCES_DIR/policy-pod-privileged.yaml
	kubectl delete --ignore-not-found -f $RESOURCES_DIR/policy-server.yaml
	kubectl delete pods --all
}

@test "[CA reconciliation] A secret with policy server certificate should be created" {
	kubectl apply -f $RESOURCES_DIR/policy-server.yaml
	kubectl wait policyserver e2e-tests --for=condition=ServiceReconciled
	retry "kubectl get secret -n $NAMESPACE policy-server-e2e-tests"
}
@test "[CA reconciliation] Policy server should store the secret resource version" {
	secretVersion=$(kubectl get secret -n $NAMESPACE policy-server-e2e-tests -o json | jq ".metadata.resourceVersion")
	retry "kubectl get pods -n $NAMESPACE -l \"kubewarden/policy-server-certificate-sercret-version=$secretVersion\" -l \"kubewarden/policy-server=e2e-tests\" "
}

@test "[CA reconciliation] Policy Server secret should be recreated after deletion" {
	kubectl delete --wait secret -n $NAMESPACE  policy-server-e2e-tests
	retry "kubectl get secret -n $NAMESPACE policy-server-e2e-tests"
}

@test "[CA reconciliation] Policy server should store the latest secret resource version after an update" {
	secretVersion=$(kubectl get secret -n $NAMESPACE policy-server-e2e-tests -o json | jq ".metadata.resourceVersion")
	retry "kubectl get pods -n $NAMESPACE -l \"kubewarden/policy-server-certificate-sercret-version=$secretVersion\" -l \"kubewarden/policy-server=e2e-tests\" "
}

@test "[CA reconciliation] Policy Server secret should be deleted if policy server is deleted" {
	kubectl delete --wait policyserver -n $NAMESPACE  e2e-tests
	wait_for_failure "kubectl get secret -n $NAMESPACE  policy-server-e2e-tests"
}

@test "[CA reconciliation] Policy webhooks should use root CA certificate to validate server" {
	apply_cluster_admission_policy $RESOURCES_DIR/privileged-pod-policy.yaml
	apply_admission_policy $RESOURCES_DIR/policy-pod-privileged.yaml

	ca=$(kubectl get secret -n kubewarden kubewarden-root-ca -o json | jq ".data.\"cert-pem\"")

	caBundle=$(kubectl get Validatingwebhookconfigurations clusterwide-privileged-pods -o json | jq ".webhooks[0].clientConfig.caBundle")
	[[ "$ca" == "$caBundle" ]]

	caBundle=$(kubectl get Validatingwebhookconfigurations namespaced-default-pod-privileged -o json | jq ".webhooks[0].clientConfig.caBundle")
	[[ "$ca" == "$caBundle" ]]
}
