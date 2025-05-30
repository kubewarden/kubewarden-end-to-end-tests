#!/usr/bin/env bash
set -aeEuo pipefail

load "../helpers/bats-support/load.bash"
load "../helpers/bats-assert/load.bash"
load "../helpers/kubelib.sh"

# ==================================================================================================
# Functions specific to kubewarden tests (require bats)

kubectl() { command kubectl --context "$CLUSTER_CONTEXT" --warnings-as-errors "$@"; }
helm()    { command helm --kube-context "$CLUSTER_CONTEXT" "$@"; }
helmer()  { "$BATS_TEST_DIRNAME/../scripts/helmer.sh" "$@"; }

# Export for retry function (subshell)
export -f kubectl helm

# ==================================================================================================

setup_helper() {
    # Stop after the first failure
    [ ! -f "${BATS_RUN_TMPDIR}/.skip" ] || skip "fail"

    # Write skip file on failure
    bats::on_failure() {
        # shellcheck disable=SC2317
        echo "$BATS_TEST_FILENAME" > "${BATS_RUN_TMPDIR}/.skip"
        # Collect logs (here or teardown?)
        # kubectl logs -n kubewarden -l app.kubernetes.io/component=controller
        # kubectl logs -n kubewarden -l app.kubernetes.io/component=policy-server
    }

    # Wait for kubewarden pods unless --no-wait tag is set
    [[ $BATS_TEST_TAGS =~ setup:--no-wait ]] || wait_pods -n "$NAMESPACE"
}

# Skip teardown if tests failed & KEEP is set
teardown_helper() {
    # Conditional skip (based on .skip file & KEEP var)
    if [[ -f "$BATS_RUN_TMPDIR/.skip" ]]; then
        if [[ "$BATS_TEST_FILENAME" == "$(< "$BATS_RUN_TMPDIR/.skip")" ]]; then
            [[ -n "${KEEP:-}" ]] && skip "skip teardown of failed test"
        else
            skip "skip teardown of remaining tests"
        fi
    fi
    # Common teardown
    kubectl delete pods --all
    kubectl delete ap,cap,apg,capg --all -A
}

trigger_audit_scan() {
    local jobname=${1:-auditjob}
    kubectl create job --from=cronjob/audit-scanner "$jobname" --namespace "$NAMESPACE" | grep "$jobname created"
    kubectl wait --timeout=3m --for=condition="Complete" job "$jobname" --namespace "$NAMESPACE"
    kubectl delete job "$jobname" --namespace "$NAMESPACE"
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

    local pfile kind
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
    kind=$(yq '.kind' "$pfile")
    kubectl apply -f "$pfile" "$@"

    # Wait for the policy to be active and uniquely reachable
    if [ ! -v nowait ]; then
        wait_for --for=condition="PolicyActive" "$kind" --all -A
        wait_policyserver default
        wait_for --for=condition="PolicyUniquelyReachable" "$kind" --all -A
    fi
}

function delete_policy {
    kubectl delete --wait -f "$(policypath "$1")" "${@:2}"
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

# When we test new features we might requite latest/stable policy-server
# This deploys same image as defaults, utilizing LATEST=1 hack if needed
# create_policyserver [name]
function create_policyserver {
    local name="${1:-pserver}"
    local image
    image="ghcr.io/$(helm get values -a kubewarden-defaults -n kubewarden -o json | jq -er '.policyServer.image | .repository + ":"+ .tag')"
    kubectl apply -f - <<EOF
apiVersion: policies.kubewarden.io/v1
kind: PolicyServer
metadata:
  name: $name
spec:
  image: $image
  replicas: 1
EOF

    wait_policyserver "$name"
}

# wait_policyserver [name]
function wait_policyserver {
    local name="${1:-default}"
    # Wait for specific revision to prevent changes during rollout
    revision=$(kubectl -n "$NAMESPACE" get "deployment/policy-server-$name" -o json | jq -er '.metadata.annotations."deployment.kubernetes.io/revision"')
    wait_rollout --revision "$revision" "deployment/policy-server-$name"
    # Wait for final rollout?
    wait_rollout "deployment/policy-server-$name"
}
