#!/usr/bin/env bats

setup() {
    setup_helper
}

function kubewarden_uninstall {
    helmer uninstall defaults --ignore-not-found
    helmer uninstall controller
    helmer uninstall crds
}

# assert_crds true|false
function assert_crds {
    run kubectl api-resources --no-headers
    if $1; then
        assert_line --regexp '\sClusterReport$'
        assert_line --regexp '\sReport$'
    else
        refute_line --regexp '\sClusterReport$'
        refute_line --regexp '\sReport$'
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

@test "$(tfile) Reconfigure audit scanner" {
    helmer set kubewarden-controller --set auditScanner.cronJob.schedule="*/30 * * * *"
    run kubectl get cronjob -n $NAMESPACE
    assert_output -p audit-scanner
    assert_output -p "*/30 * * * *"
}

@test "$(tfile) Audit scanner resources are cleaned with kubewarden" {
    kubewarden_uninstall
    assert_crds false
    assert_cronjob false
}

# bats test_tags=setup:--no-wait
@test "$(tfile) Install with CRDs pre-installed" {
    # Install kubewarden with custom policyreport-crds
    kubectl apply -f https://raw.githubusercontent.com/openreports/reports-api/refs/heads/main/config/install.yaml
    assert_crds true

    # Install kubewarden with existing policyreport crds
    helmer reinstall crds --set installOpenReportsCRDs=False
    helmer reinstall controller
    assert_cronjob true

    # Check policy reports did not come from helm (have no labels)
    kubectl get crds reports.openreports.io -o json | jq -e '.metadata.labels == null'
    kubectl get crds clusterreports.openreports.io -o json | jq -e '.metadata.labels == null'

    # Kubewarden should not remove custom crds
    kubewarden_uninstall
    assert_crds true
    assert_cronjob false

    kubectl delete -f https://raw.githubusercontent.com/openreports/reports-api/refs/heads/main/config/install.yaml
    assert_crds false
}

# bats test_tags=setup:--no-wait
@test "$(tfile) Install with CRDs from Kubewarden Helm charts" {
    helmer reinstall
    assert_crds true
    assert_cronjob true

    # Check crds were installed by helm
    kubectl get crds reports.openreports.io --show-labels | grep 'managed-by=Helm'
    kubectl get crds clusterreports.openreports.io --show-labels | grep 'managed-by=Helm'
}
