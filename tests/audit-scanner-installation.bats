#!/usr/bin/env bats

setup() {
  load common.bash
  wait_pods -n kube-system
}

CRD_BASE=https://github.com/kubernetes-sigs/wg-policy-prototypes/raw/master/policy-report/crd/v1alpha2/

# assert_crds true|false
function assert_crds {
    run kubectl api-resources
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

@test "[Audit Scanner] Reconfigure audit scanner" {
    helm_up kubewarden-controller --reuse-values --set auditScanner.cronJob.schedule="*/30 * * * *" 
    run kubectl get cronjob -n $NAMESPACE
    assert_output -p audit-scanner
    assert_output -p "*/30 * * * *"
}

@test "[Audit Scanner] Audit scanner resources are cleaned with kubewarden" {
    kubewarden_remove
    assert_crds false
    assert_cronjob false
}

@test "[Audit Scanner] Install with CRDs pre-installed" {
    # Install kubewarden with custom policyreport-crds
    kubectl create -f $CRD_BASE/wgpolicyk8s.io_policyreports.yaml
    kubectl create -f $CRD_BASE/wgpolicyk8s.io_clusterpolicyreports.yaml
    assert_crds true

    # Install kubewarden with existing policyreport crds
    helm_in kubewarden-crds --set installPolicyReportCRDs=False
    helm_in kubewarden-controller
    assert_cronjob true

    # Check policy reports did not come from helm (have no labels)
    kubectl get crds policyreports.wgpolicyk8s.io -o json | jq -e '.metadata.labels == null'
    kubectl get crds clusterpolicyreports.wgpolicyk8s.io -o json | jq -e '.metadata.labels == null'

    # Kubewarden should not remove custom crds
    kubewarden_remove
    assert_crds true
    assert_cronjob false

    kubectl delete -f $CRD_BASE/wgpolicyk8s.io_policyreports.yaml
    kubectl delete -f $CRD_BASE/wgpolicyk8s.io_clusterpolicyreports.yaml
    assert_crds false
}

@test "[Audit Scanner] Install with CRDs from Kubewarden Helm charts" {
    helm_in kubewarden-crds
    helm_in kubewarden-controller
    assert_crds true
    assert_cronjob true

    # Check crds were installed by helm
    kubectl get crds policyreports.wgpolicyk8s.io --show-labels | grep 'managed-by=Helm'
    kubectl get crds clusterpolicyreports.wgpolicyk8s.io --show-labels | grep 'managed-by=Helm'
}
