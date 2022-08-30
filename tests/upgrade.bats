#!/usr/bin/env bats

setup() {
	load common.bash
	wait_pods
}

function helm_in {
    helm upgrade --install --wait --namespace $NAMESPACE --create-namespace \
        "${@:2}" $1 $KUBEWARDEN_CHARTS_LOCATION/$1
}

# check_apiversion admissionpolicies v1
function check_apiversion {
    run -0 bash -c "kubectl get $1 -o json | jq -er '.items[].apiVersion' | uniq"
    assert_output "policies.kubewarden.io/$2"
}

function check_default_policies {
    # Check all policies are in v1
    check_apiversion clusteradmissionpolicies v1
    wait_for_cluster_admission_policy PolicyUniquelyReachable

    # Run privileged pod (should fail)
    # kubefail_privileged run pod-privileged --image=k8s.gcr.io/pause --privileged
    # Workaround - https://suse.slack.com/archives/C02DBSK7HC1/p1661518752112929
    run -1 kubectl run pod-privileged --image=k8s.gcr.io/pause --privileged
}


@test "[CRD upgrade] Install old Kubewarden" {
    # Install old kubewarden version
    helm_in kubewarden-crds --version $KUBEWARDEN_CRDS_CHART_OLD_VERSION
    helm_in kubewarden-controller --version $KUBEWARDEN_CONTROLLER_CHART_OLD_VERSION
    helm_in kubewarden-defaults --version $KUBEWARDEN_DEFAULTS_CHART_OLD_VERSION \
        --set recommendedPolicies.enabled=True \
        --set recommendedPolicies.defaultPolicyMode=protect
    check_default_policies
}

@test "[CRD upgrade] Upgrade Kubewarden" {
    helm_in kubewarden-crds --version $KUBEWARDEN_CRDS_CHART_VERSION
    helm_in kubewarden-controller --version $KUBEWARDEN_CONTROLLER_CHART_VERSION
    helm_in kubewarden-defaults --version $KUBEWARDEN_DEFAULTS_CHART_VERSION
    check_default_policies
}

@test "[CRD upgrade] Check old policy CRD version is translated to new" {
	sed '/apiVersion:/ s#/v1.*#/v1alpha2#' $RESOURCES_DIR/policy-pod-privileged.yaml | apply_admission_policy
	check_apiversion admissionPolicy v1
	kubectl delete -f $RESOURCES_DIR/policy-pod-privileged.yaml
}

@test "[CRD upgrade] Disable default policies & run privileged pod" {
	helm_in kubewarden-defaults --set recommendedPolicies.enabled=False
	wait_rollout -n $NAMESPACE "deployment/policy-server-default"
	kubectl run pod-privileged --image=k8s.gcr.io/pause --privileged
}
