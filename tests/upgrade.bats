#!/usr/bin/env bats

source $BATS_TEST_DIRNAME/common.bash

@test "[CRD upgrade] Install old Kubewarden version" {
	helm install --wait --kube-context $CLUSTER_CONTEXT \
		--namespace $NAMESPACE --create-namespace \
		--version "$KUBEWARDEN_CRDS_CHART_OLD_VERSION" \
		kubewarden-crds $KUBEWARDEN_CHARTS_LOCATION/kubewarden-crds

	helm install --wait --namespace $NAMESPACE --kube-context $CLUSTER_CONTEXT \
		--values $RESOURCES_DIR/default-kubewarden-controller-values.yaml \
		--version "$KUBEWARDEN_CONTROLLER_CHART_OLD_VERSION" \
		kubewarden-controller $KUBEWARDEN_CHARTS_LOCATION/kubewarden-controller

	yq --in-place -Y ".recommendedPolicies.enabled=true" $RESOURCES_DIR/default-kubewarden-defaults-values.yaml
	yq --in-place -Y ".recommendedPolicies.defaultPolicyMode=\"protect\"" $RESOURCES_DIR/default-kubewarden-defaults-values.yaml

	helm install --wait --namespace $NAMESPACE --kube-context $CLUSTER_CONTEXT \
		--values $RESOURCES_DIR/default-kubewarden-defaults-values.yaml \
		--version "$KUBEWARDEN_DEFAULTS_CHART_OLD_VERSION" \
		kubewarden-defaults $KUBEWARDEN_CHARTS_LOCATION/kubewarden-defaults

	crd_version=$(kubectl --context $CLUSTER_CONTEXT get clusteradmissionpolicy -o json | jq -r ".items[].apiVersion" | uniq)
	[ "$crd_version" = "policies.kubewarden.io/v1alpha2" ]
	wait_for_all_cluster_admission_policy_condition PolicyUniquelyReachable
}

@test "[CRD upgrade] Launch a privileged pod should fail" {
	kubectl_apply_should_fail $RESOURCES_DIR/violate-privileged-pod-policy.yaml
}

@test "[CRD upgrade] Upgrade CRDs" {
	helm upgrade --wait --kube-context $CLUSTER_CONTEXT \
		--namespace $NAMESPACE --create-namespace \
		--version $KUBEWARDEN_CRDS_CHART_VERSION \
		kubewarden-crds $KUBEWARDEN_CHARTS_LOCATION/kubewarden-crds

	helm upgrade --wait --namespace $NAMESPACE --kube-context $CLUSTER_CONTEXT \
		--values $RESOURCES_DIR/default-kubewarden-controller-values.yaml \
		--version $KUBEWARDEN_CONTROLLER_CHART_VERSION \
		kubewarden-controller $KUBEWARDEN_CHARTS_LOCATION/kubewarden-controller

	yq --in-place -Y ".recommendedPolicies.enabled=true" $RESOURCES_DIR/default-kubewarden-defaults-values.yaml
	yq --in-place -Y ".recommendedPolicies.defaultPolicyMode=\"protect\"" $RESOURCES_DIR/default-kubewarden-defaults-values.yaml
	helm upgrade --wait --namespace $NAMESPACE --kube-context $CLUSTER_CONTEXT \
		--values $RESOURCES_DIR/default-kubewarden-defaults-values.yaml \
		--version $KUBEWARDEN_DEFAULTS_CHART_VERSION \
		kubewarden-defaults $KUBEWARDEN_CHARTS_LOCATION/kubewarden-defaults

	crd_version=$(kubectl --context $CLUSTER_CONTEXT get clusteradmissionpolicy -o json | jq -r ".items[].apiVersion" | uniq)
	[ "$crd_version" = "policies.kubewarden.io/v1" ]
	wait_for_all_cluster_admission_policy_condition PolicyUniquelyReachable
}

@test "[CRD upgrade] Launch a privileged pod should fail after CRD upgrade" {
	kubectl_apply_should_fail $RESOURCES_DIR/violate-privileged-pod-policy.yaml
}

@test "[CRD upgrade] Try to install a object with a old CRD version" {
	apply_admission_policy $RESOURCES_DIR/namespaced-privileged-pod-policy.yaml
	crd_version=$(kubectl --context $CLUSTER_CONTEXT get admissionPolicy -o json | jq -r ".items[].apiVersion" | uniq)
	[ "$crd_version" = "policies.kubewarden.io/v1" ]
}

@test "[CRD upgrade] Privileged pod should be launched after delete old policies" {
	kubectl --context $CLUSTER_CONTEXT delete --wait --ignore-not-found -n kubewarden clusteradmissionpolicies --all
	kubectl --context $CLUSTER_CONTEXT create namespace testns

	kubectl_namespace_apply_should_succeed $RESOURCES_DIR/violate-privileged-pod-policy.yaml testns
}

