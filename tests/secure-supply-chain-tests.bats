#!/usr/bin/env bats

source $BATS_TEST_DIRNAME/common.bash

SECURE_SUPPLY_CHAIN_VERIFICATION_CONFIG_MAP_NAME="ssc-verification-config"

teardown_file() {
	helm upgrade --set policyServer.verificationConfig="" --wait -n kubewarden kubewarden-defaults kubewarden/kubewarden-defaults
	wait_for_default_policy_server_rollout
	kubectl_delete_configmap_by_name $SECURE_SUPPLY_CHAIN_VERIFICATION_CONFIG_MAP_NAME
}

setup() {
	clean_up_environment
	kubectl_delete_configmap_by_name $SECURE_SUPPLY_CHAIN_VERIFICATION_CONFIG_MAP_NAME
}

@test "[Secure Supply Chain tests] Trusted policy should not block policy server" {
	create_configmap_from_file_with_root_key $SECURE_SUPPLY_CHAIN_VERIFICATION_CONFIG_MAP_NAME verification-config $RESOURCES_DIR/secure-supply-chain-verification-config.yaml
	helm upgrade --set policyServer.verificationConfig=$SECURE_SUPPLY_CHAIN_VERIFICATION_CONFIG_MAP_NAME --wait -n kubewarden kubewarden-defaults kubewarden/kubewarden-defaults
	# this function will wait the policy server to rollout. Which shows that signatures are valid
	apply_admission_policy $RESOURCES_DIR/namespaced-privileged-pod-policy.yaml
}

@test "[Secure Supply Chain tests] Untrusted policy should block policy server to run" {
	create_configmap_from_file_with_root_key $SECURE_SUPPLY_CHAIN_VERIFICATION_CONFIG_MAP_NAME verification-config $RESOURCES_DIR/restricted-secure-supply-chain-verification-config.yaml
	kubectl_delete $RESOURCES_DIR/namespaced-privileged-pod-policy.yaml
	wait_for_default_policy_server_rollout
	helm upgrade --set policyServer.verificationConfig=$SECURE_SUPPLY_CHAIN_VERIFICATION_CONFIG_MAP_NAME --wait -n kubewarden kubewarden-defaults kubewarden/kubewarden-defaults
	wait_for_default_policy_server_rollout
	kubectl_apply_should_succeed $RESOURCES_DIR/namespaced-privileged-pod-policy.yaml
	# Policy Server startup should fail
	default_policy_server_rollout_should_fail
}

