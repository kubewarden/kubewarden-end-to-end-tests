#!/usr/bin/env bats
#
# This test requires signed package. To sign follow this steps & modify configmaps accordingly
# $ kwctl pull registry://ghcr.io/kubewarden/policies/pod-privileged:v0.2.1
# $ kwctl push
#    ~/.cache/kubewarden/store/registry/ghcr.io/kubewarden/policies/pod-privileged:v0.2.1 \
#    ghcr.io/kubewarden/tests/pod-privileged:v0.2.1
# $ COSIGN_PASSWORD=kubewarden cosign generate-key-pair
# $ COSIGN_PASSWORD=kubewarden cosign sign --key cosign.key -a env=prod ghcr.io/kubewarden/tests/pod-privileged:v0.2.1


CONFIGMAP_NAME="ssc-verification-config"

setup() {
	load common.bash
	wait_pods # -n kubewarden
}

teardown() {
	kubectl -n $NAMESPACE delete configmap $CONFIGMAP_NAME
	kubectl delete -f $RESOURCES_DIR/policy-pod-privileged.yaml
}

# Configure kubewarden to check policy signatures
# https://docs.kubewarden.io/distributing-policies/secure-supply-chain#configuring-the-policy-server-to-check-policy-signatures
setup_file() {
	helm upgrade -n kubewarden --set policyServer.verificationConfig=$CONFIGMAP_NAME --wait kubewarden-defaults kubewarden/kubewarden-defaults
	kubectl get policyserver default -o json | jq -e --arg cmname $CONFIGMAP_NAME '.spec.verificationConfig == $cmname'
	# don't wait for rollout here, it needs configmap to run
}

teardown_file() {
	helm upgrade -n kubewarden --set policyServer.verificationConfig="" --wait kubewarden-defaults kubewarden/kubewarden-defaults
}

function create_configmap {
	kubectl -n $NAMESPACE create configmap $CONFIGMAP_NAME --from-file=verification-config=$1
}

function get_policy_server_status {
	# get latest policy-server pod
	local podname=$(kubectl get pods -n kubewarden --selector=app=kubewarden-policy-server-default --sort-by=.metadata.creationTimestamp -o jsonpath="{.items[-1].metadata.name}")
	# fill output with logs, 10s timeout because pod restart cleans up
	kubectl logs -n kubewarden $podname --request-timeout=10s -f

	# fill exit code with pod status
	kubectl get pod -n kubewarden $podname -o json | jq -e '.status.containerStatuses[0].ready == true'
}

@test "[Secure Supply Chain tests] Trusted policy should not block policy server" {
	create_configmap $RESOURCES_DIR/secure-supply-chain-cm.yaml
	wait_rollout -n $NAMESPACE "deployment/policy-server-default"

	# Policy Server should start fine
	apply_admission_policy $RESOURCES_DIR/policy-pod-privileged.yaml

	# Check logs of last policyserver pod
	run -0 get_policy_server_status
	assert_output -p 'verifying policy authenticity and integrity using sigstore'
	assert_output -p 'Local file checksum verification passed'

	# Cleanup moved to teardown
}

@test "[Secure Supply Chain tests] Untrusted policy should block policy server to run" {
	create_configmap $RESOURCES_DIR/secure-supply-chain-cm-restricted.yaml

	# Policy Server should start fine
	kubectl apply -f $RESOURCES_DIR/policy-pod-privileged.yaml

	# Policy Server startup should fail
	run kubectl -n $NAMESPACE rollout status --timeout=1m "deployment/policy-server-default"
	assert_failure 1

	# Check logs of last policyserver pod
	run -1 get_policy_server_status
	assert_output -p 'Annotation not satisfied'
	assert_output -p 'policy cannot be verified'

	# Cleanup moved to teardown
}
