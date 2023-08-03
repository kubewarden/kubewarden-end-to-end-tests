#!/usr/bin/env bats

setup() {
  load common.bash
  wait_pods -n kube-system
}

@test "[Audit Scanner] Install with CRDs pre-installed" {
    run kubectl api-resources
    refute_output -p 'ClusterPolicyReport'
    refute_output -p 'PolicyReport'
    run kubectl get cronjob -A
    refute_output -p audit-scanner

    kubectl create -f https://github.com/kubernetes-sigs/wg-policy-prototypes/raw/master/policy-report/crd/v1alpha2/wgpolicyk8s.io_policyreports.yaml
    kubectl create -f https://github.com/kubernetes-sigs/wg-policy-prototypes/raw/master/policy-report/crd/v1alpha2/wgpolicyk8s.io_clusterpolicyreports.yaml

    helm_in kubewarden-crds --set installPolicyReportCRDs=False
    helm_in kubewarden-controller
    helm_in kubewarden-defaults  \
        --set recommendedPolicies.enabled=True \
        --set recommendedPolicies.defaultPolicyMode=protect

    run kubectl api-resources
    assert_output -p 'ClusterPolicyReport'
    assert_output -p 'PolicyReport'

    run kubectl get cronjob -A
    assert_output -p audit-scanner

    helm_rm kubewarden-defaults
    helm_rm kubewarden-controller
    helm_rm kubewarden-crds

    run kubectl api-resources
    assert_output -p 'ClusterPolicyReport'
    assert_output -p 'PolicyReport'
    run kubectl get cronjob -A
    refute_output -p audit-scanner

    kubectl delete -f https://github.com/kubernetes-sigs/wg-policy-prototypes/raw/master/policy-report/crd/v1alpha2/wgpolicyk8s.io_policyreports.yaml
    kubectl delete -f https://github.com/kubernetes-sigs/wg-policy-prototypes/raw/master/policy-report/crd/v1alpha2/wgpolicyk8s.io_clusterpolicyreports.yaml
    run kubectl api-resources
    refute_output -p 'ClusterPolicyReport'
    refute_output -p 'PolicyReport'
}

@test "[Audit Scanner] Install with CRDs from Kubewarden Helm charts" {
    run kubectl api-resources
    refute_output -p 'ClusterPolicyReport'
    refute_output -p 'PolicyReport'
    run kubectl get cronjob -A
    refute_output -p audit-scanner

    helm_in kubewarden-crds # defaults to installPolicyReportCRDs=True
    helm_in kubewarden-controller
    helm_in kubewarden-defaults  \
        --set recommendedPolicies.enabled=True \
        --set recommendedPolicies.defaultPolicyMode=protect

    run kubectl api-resources
    assert_output -p 'ClusterPolicyReport'
    assert_output -p 'PolicyReport'

    run kubectl get cronjob -A
    assert_output -p audit-scanner
}

@test "[Audit Scanner] Reconfigure audit scanner" {
    helm_up kubewarden-controller --reuse-values --set auditScanner.cronJob.schedule="*/30 * * * *" 

    run kubectl get cronjob -A
    assert_output -p audit-scanner
    assert_output -p "*/30 * * * *"
}

@test "[Audit Scanner] Uninstall audit scanner" {
    helm_rm kubewarden-defaults
    helm_rm kubewarden-controller
    helm_rm kubewarden-crds

    run kubectl api-resources
    refute_output -p 'ClusterPolicyReport'
    refute_output -p 'PolicyReport'
    run kubectl get cronjob -A
    refute_output -p audit-scanner
}
