#!/usr/bin/env bats

setup() {
    load ../helpers/helpers.sh
    wait_pods -n kube-system
}

# Hardcode PolicyReports to v1alpha2 from clusterpolicyreports.wgpolicyk8s.io and not clusterpolicyreports.x-k8s.io
# We will need to migrate later in time.
CRD_BASE=https://raw.githubusercontent.com/kubernetes-sigs/wg-policy-prototypes/af8c5984c89aa95d8a6719d3994e71ecc31ce6c3/policy-report/crd/v1alpha2/

function kubewarden_uninstall {
    helmer uninstall defaults --ignore-not-found
    helmer uninstall controller
    helmer uninstall crds
}

# assert_crds true|false
function assert_crds {
    run kubectl api-resources --no-headers
    if $1; then
        assert_output -p 'ClusterPolicyReport'
        assert_output -p 'PolicyReport'
    else
        refute_output -p 'ClusterPolicyReport'
        refute_output -p 'PolicyReport'
    fi
}

# assert_cronjob true|false
function assert_cronjob {
    run kubectl get cronjob -n $NAMESPACE
    if $1; then
        assert_output -p audit-scanner
    else
        refute_output -p audit-scanner
    fi
}

@test "[Audit Scanner Installation] Reconfigure audit scanner" {
    helmer set kubewarden-controller --set auditScanner.cronJob.schedule="*/30 * * * *"
    run kubectl get cronjob -n $NAMESPACE
    assert_output -p audit-scanner
    assert_output -p "*/30 * * * *"
}

@test "[Audit Scanner Installation] Audit scanner resources are cleaned with kubewarden" {
    kubewarden_uninstall
    assert_crds false
    assert_cronjob false
}

@test "[Audit Scanner Installation] Install with CRDs pre-installed" {
    # Install kubewarden with custom policyreport-crds
    kubectl create -f $CRD_BASE/wgpolicyk8s.io_policyreports.yaml
    kubectl create -f $CRD_BASE/wgpolicyk8s.io_clusterpolicyreports.yaml
    assert_crds true

    # Install kubewarden with existing policyreport crds
    helmer reinstall crds --set installPolicyReportCRDs=False
    helmer reinstall controller
    assert_cronjob true

    # Check policy reports did not come from helm (have no labels)
    kubectl get crds policyreports.wgpolicyk8s.io -o json | jq -e '.metadata.labels == null'
    kubectl get crds clusterpolicyreports.wgpolicyk8s.io -o json | jq -e '.metadata.labels == null'

    # Kubewarden should not remove custom crds
    kubewarden_uninstall
    assert_crds true
    assert_cronjob false

    kubectl delete -f $CRD_BASE/wgpolicyk8s.io_policyreports.yaml
    kubectl delete -f $CRD_BASE/wgpolicyk8s.io_clusterpolicyreports.yaml
    assert_crds false
}

@test "[Audit Scanner Installation] Install with CRDs from Kubewarden Helm charts" {
    helmer reinstall
    assert_crds true
    assert_cronjob true

    # Check crds were installed by helm
    kubectl get crds policyreports.wgpolicyk8s.io --show-labels | grep 'managed-by=Helm'
    kubectl get crds clusterpolicyreports.wgpolicyk8s.io --show-labels | grep 'managed-by=Helm'
}
