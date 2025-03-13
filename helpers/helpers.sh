#!/usr/bin/env bash

bats_require_minimum_version 1.7.0

load "../helpers/bats-support/load.bash"
load "../helpers/bats-assert/load.bash"
load "../helpers/kubelib.sh"

# ==================================================================================================
# Functions specific to kubewarden tests (require bats)

kubectl() { command kubectl --context "$CLUSTER_CONTEXT" --warnings-as-errors "$@"; }
helm()    { command helm --kube-context "$CLUSTER_CONTEXT" "$@"; }
helmer()  { $BATS_TEST_DIRNAME/../scripts/helmer.sh "$@"; }

# Export for retry function (subshell)
export -f kubectl helm

# ==================================================================================================

trigger_audit_scan() {
    local jobname=${1:-auditjob}
    kubectl create job --from=cronjob/audit-scanner $jobname --namespace $NAMESPACE | grep "$jobname created"
    kubectl wait --timeout=3m --for=condition="Complete" job $jobname --namespace $NAMESPACE
    kubectl delete job $jobname --namespace $NAMESPACE
}

# Run & delete pod with optional parameters. Check exit code.
# kuberun [-0|-1|-N|!] "--privileged"
function kuberun {
    local status=-0
    [[ $1 =~ ^([!]|-[0-9]+)$ ]] && status="$1" && shift
    run "$status" kubectl run "pod-$(date +%s)" --image=busybox --restart=Never --rm -it --command "$@" -- true
}

# Run kubectl action which should fail on pod privileged policy
function kubefail_privileged {
    run kubectl "$@"
    assert_failure 1
    assert_output --regexp '^Error.*: admission webhook.*denied the request.*container is not allowed$'
}

# Run kubectl action which should fail on pod using privileged escalation or shared pid namespace without the mandatory annotation
function kubefail_policy_group {
    run kubectl "$@"
    assert_failure 1
    assert_output --regexp '^Error.*: admission webhook.*denied the request: the pod is using privileged escalation or shared pid namespace and has not the mandatory annotation$'
}

# Prepend policies with RESOURCE dir if file doesn't contain '/'
policypath() { [[ "$1" == */* ]] && echo "$1" || echo "$RESOURCES_DIR/policies/$1"; }

# Deploy from pipe or resources dir (if parameter doesn't contain '/')
# Detect policy kind and wait for it to be active and uniquely reachable
# Works only with default policy server
function apply_policy {
    [ "${1:-}" = '--no-wait' ] && local nowait=true && shift

    local pfile
    if [[ $# -eq 0 || "$1" == -* ]]; then
        # Policy yaml from pipe (-p /dev/stdin fails on github runner)
        pfile=$(mktemp -p "$BATS_RUN_TMPDIR" policy-XXXXX.yaml)
        cat > "$pfile"
    else
        # Policy from resource file
        pfile=$(policypath "$1")
        shift
    fi

    # Find policy kind and apply
    local kind=$(yq '.kind' "$pfile")
    kubectl apply -f "$pfile" "$@"

    # Wait for the policy to be active and uniquely reachable
    if [ ! -v nowait ]; then
        wait_for --for=condition="PolicyActive" "$kind" --all -A
        wait_policyserver default
        wait_for --for=condition="PolicyUniquelyReachable" "$kind" --all -A
    fi
}

function delete_policy {
    local pfile=$(policypath "$1")
    kubectl delete --wait -f "$pfile" "${@:2}"
}

# wait_policies [condition] - at least one policy must exist
function wait_policies {
    local resources="admissionpolicies,clusteradmissionpolicies"
    # Policy groups were added in Kubewarden >= v1.17.0
    kw_version ">=1.17" && resources+=",admissionpolicygroups,clusteradmissionpolicygroups"

    for state in ${1:-PolicyActive PolicyUniquelyReachable}; do
        wait_for --for=condition="$state" "$resources" --all -A
    done
}

# wait_policyserver [name]
function wait_policyserver {
    local name="${1:-default}"
    # Wait for specific revision to prevent changes during rollout
    revision=$(kubectl -n $NAMESPACE get "deployment/policy-server-$name" -o json | jq -er '.metadata.annotations."deployment.kubernetes.io/revision"')
    wait_rollout -n $NAMESPACE --revision $revision "deployment/policy-server-$name"
    # Wait for final rollout?
    wait_rollout -n $NAMESPACE "deployment/policy-server-$name"
}
