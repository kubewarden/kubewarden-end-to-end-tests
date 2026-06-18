#!/usr/bin/env bats

# UI access:
# kubectl port-forward -n prometheus --address 0.0.0.0 svc/prometheus-operated 9090
# kubectl port-forward -n jaeger svc/my-open-telemetry-query 16686:16686

setup() {
    setup_helper
    load "../helpers/opentelemetry.sh"
}

teardown_file() {
    teardown_helper

    # Remote otel collector cleanup
    kubectl delete --ignore-not-found -f $RESOURCES_DIR/opentelemetry-jaeger.yaml
    kubectl delete --ignore-not-found --namespace $NAMESPACE -f $RESOURCES_DIR/otel-collector-deployment.yaml

    # Remove installed apps
    helm uninstall --wait -n jaeger jaeger-operator 2>/dev/null || true
    helm uninstall --wait -n prometheus prometheus 2>/dev/null || true
    helm uninstall --wait -n open-telemetry my-opentelemetry-operator 2>/dev/null || true
    helm uninstall --wait -n cert-manager cert-manager 2>/dev/null || true

    helmer reset admission-controller
}

@test "$(tfile) Install OpenTelemetry, Prometheus, Jaeger" {
    # Required by OpenTelemetry
    helm repo add e2e-jetstack https://charts.jetstack.io --force-update
    helm upgrade -i --wait cert-manager e2e-jetstack/cert-manager \
        -n cert-manager --create-namespace \
        --set crds.enabled=true

    # OpenTelemetry
    # https://github.com/open-telemetry/opentelemetry-helm-charts/blob/main/charts/opentelemetry-operator/UPGRADING.md
    helm repo add --force-update open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
    helm upgrade -i --wait my-opentelemetry-operator open-telemetry/opentelemetry-operator \
        --set "manager.collectorImage.repository=ghcr.io/open-telemetry/opentelemetry-collector-releases/opentelemetry-collector-contrib" \
        --version "${OTEL_OPERATOR:-*}" \
        -n open-telemetry --create-namespace

    # Prometheus
    helm repo add --force-update prometheus-community https://prometheus-community.github.io/helm-charts
    helm upgrade -i --wait prometheus prometheus-community/kube-prometheus-stack \
        -n prometheus --create-namespace \
        --values $RESOURCES_DIR/opentelemetry-prometheus.yaml

    # Jaeger
    helm repo add --force-update jaegertracing https://jaegertracing.github.io/helm-charts
    helm upgrade -i --wait jaeger-operator jaegertracing/jaeger-operator \
        -n jaeger --create-namespace \
        --set rbac.clusterRole=true
    # Wait for service: Internal error occurred: failed calling webhook "mjaeger.kb.io": failed to call webhook
    retry "kuberun wget -O- https://jaeger-operator-webhook-service.jaeger.svc/mutate-jaegertracing-io-v1-jaeger" 2 10

    kubectl apply -f $RESOURCES_DIR/opentelemetry-jaeger.yaml
    wait_pods -n jaeger

    # Setup Kubewarden
    helmer set admission-controller --set recommendedPolicies.enabled=True --values $RESOURCES_DIR/opentelemetry-telemetry.yaml
}

@test "$(tfile) Kubewarden containers have sidecars & metrics" {
    # Controller is restarted to get sidecar
    wait_pods -n $NAMESPACE

    # Check kubewarden pods have sidecar (otc-container) - might take a minute to start
    # k8s 1.29 moved to initContainers, support both since we test also old versions
    retry "kubectl get pods -n $NAMESPACE -l 'app.kubernetes.io/component in (controller,policy-server)' -o json \
        | jq -e 'all(.items[]; (.spec.initContainers[]?, .spec.containers[]) | select(.name == \"otc-container\"))'"
    # Policy server service has the metrics ports
    kubectl get services -n $NAMESPACE  policy-server-default -o json | jq -e 'any(.spec.ports[]; .name == "metrics")'
    # Controller service has the metrics ports
    kubectl get services -n $NAMESPACE -l app.kubernetes.io/name=admission-controller -o json | jq -e 'any(.items[].spec.ports[]; .name == "metrics")'

    # Generate metric data
    kubectl run pod-privileged --image=rancher/pause:3.2 --privileged
    wait_for pod pod-privileged
    kubectl delete --wait pod pod-privileged

    # Policy server & controller metrics should be available
    retry 'test $(get_metrics policy-server-default | wc -l) -gt 10'
    retry 'test $(get_metrics admission-controller-metrics-service | wc -l) -gt 1'
}

@test "$(tfile) PolicyServer metricsPort changes the Service port" {
    # spec.metricsPort is a Service-layer setting: it changes the port on the
    # Kubernetes Service that Prometheus scrapes, but does NOT affect the port
    # the pod binds (no KUBEWARDEN_METRICS_PORT env var is injected).
    kubectl patch policyserver default --type=merge \
        -p '{"spec": {"metricsPort": 9999}}'
    wait_policyserver default

    # Verify the Service metrics port updated
    local svc_metrics_port
    svc_metrics_port=$(kubectl get svc -n "$NAMESPACE" policy-server-default \
        -o jsonpath='{.spec.ports[?(@.name=="metrics")].port}')
    [[ "$svc_metrics_port" == "9999" ]]

    # Verify metrics are still reachable through the new Service port
    retry 'test $(get_metrics policy-server-default 9999 | wc -l) -gt 10'

    # Reset to default metricsPort so downstream tests are unaffected
    kubectl patch policyserver default --type=merge \
        -p '{"spec": {"metricsPort": 8080}}'
    wait_policyserver default
}

@test "$(tfile) Audit scanner runs should generate metrics" {
    kubectl get cronjob -n $NAMESPACE audit-scanner

    # Launch unprivileged & privileged pods
    kubectl run nginx-unprivileged --image=nginx:alpine
    wait_for pod nginx-unprivileged
    kubectl run nginx-privileged --image=rancher/pause:3.2 --privileged
    wait_for pod nginx-privileged

    # Deploy some policy
    apply_policy --no-wait privileged-pod-policy.yaml
    apply_policy namespace-label-propagator-policy.yaml

    trigger_audit_scan
    retry 'test $(get_metrics policy-server-default | grep protect | grep -oE "policy_name=\"[^\"]+" | sort -u | wc -l) -eq 2'

    delete_policy privileged-pod-policy.yaml
    delete_policy namespace-label-propagator-policy.yaml
}

@test "$(tfile) Disabling telemetry should remove sidecars & metrics" {
    helmer set admission-controller \
        --set telemetry.metrics=False \
        --set telemetry.tracing=False \
        --set recommendedPolicies.enabled=False
    wait_pods -n $NAMESPACE

    # Check sidecars (otc-container) - have been removed
    retry "kubectl get pods -n $NAMESPACE -o json \
        | jq -e 'all(.items[]; (.spec.initContainers + .spec.containers | map(.name) | contains([\"otc-container\"]) | not))'"
    # Policy server service has no metrics ports
    kubectl get services -n $NAMESPACE policy-server-default -o json | jq -e 'all(.spec.ports[]; .name != "metrics")'
    # Controller service has no metrics ports
    kubectl get services -n $NAMESPACE -l app.kubernetes.io/name=admission-controller -o json | jq -e 'all(.items[].spec.ports[]; .name != "metrics")'
}

# ==================================================================================================
# Remote OTEL collector scenarios

@test "$(tfile) Custom mode: Setup remote OTEL collector" {
    kubectl apply --namespace $NAMESPACE -f $RESOURCES_DIR/otel-collector-deployment.yaml
    wait_pods -n $NAMESPACE

    helmer set admission-controller --values $RESOURCES_DIR/opentelemetry-telemetry-remote.yaml --set recommendedPolicies.enabled=True
    wait_pods -n $NAMESPACE
}

@test "$(tfile) Custom mode: Send metrics to remote OTEL collector" {
    # Generate metric data
    kubectl run pod-privileged --image=rancher/pause:3.2 --privileged
    wait_for pod pod-privileged
    kubectl delete --wait pod pod-privileged

    retry 'test $(get_metrics my-collector-collector | grep "kubewarden_policy_total" | wc -l) -gt 1'
    retry 'test $(get_metrics my-collector-collector | grep "kubewarden_policy_evaluations_total" | wc -l) -gt 1'
}

# ==================================================================================================
# HostNetwork + OTEL transition scenarios

@test "$(tfile) HostNetwork: Enable sidecar telemetry and verify baseline" {
    # Enable sidecar telemetry WITHOUT hostNetwork.
    # Pre-set custom ports on defaults in preparation for later hostNetwork use.
    helmer set admission-controller \
        --set policyServer.replicaCount=1 \
        --set policyServer.readinessProbePort=63003 \
        --set policyServer.metricsPort=63004 \
        --set policyServer.webhookPort=64005 \
        --values $RESOURCES_DIR/opentelemetry-telemetry.yaml

    wait_rollout deployment/admission-controller
    wait_policyserver default

    # Verify hostNetwork is NOT enabled
    assert_deployment_hostnetwork "app.kubernetes.io/name=admission-controller" "false"
    assert_deployment_hostnetwork "kubewarden/policy-server=default" "false"

    # Verify otc-container sidecar IS running on pods
    retry "kubectl get pods -n $NAMESPACE -l 'app.kubernetes.io/component in (controller,policy-server)' -o json \
        | jq -e 'all(.items[]; (.spec.initContainers[]?, .spec.containers[]) | select(.name == \"otc-container\"))'"

    # Verify sidecar annotation on controller deployment
    kubectl get deployment -n $NAMESPACE admission-controller -o json \
        | jq -e '.spec.template.metadata.annotations["sidecar.opentelemetry.io/inject"] == "true"'

    # Verify --enable-otel-sidecar flag in controller args
    kubectl get deployment -n $NAMESPACE admission-controller -o json \
        | jq -e '.spec.template.spec.containers[0].args | any(. == "--enable-otel-sidecar")'

    # Deploy policy and verify evaluation through sidecars
    apply_policy privileged-pod-policy.yaml

    kubectl run pause-sidecar --image=rancher/pause:3.2
    wait_for pod pause-sidecar

    kubefail_privileged run pod-priv-sidecar --image=rancher/pause:3.2 --privileged

    # Generate metric data and verify metrics through sidecar
    kubectl run pod-priv-sidecar-m --image=rancher/pause:3.2 --privileged 2>/dev/null || true
    kubectl delete pod pod-priv-sidecar-m --ignore-not-found --wait=false

    retry 'test $(get_metrics policy-server-default 63004 | wc -l) -gt 10'
}

@test "$(tfile) HostNetwork: Switch to custom telemetry and enable hostNetwork" {
    # Combined transition: sidecar → custom telemetry AND hostNetwork=false → true
    # in a single Helm upgrade.
    helmer set admission-controller --set hostNetwork=true \
        --set ports.webhook=63000 \
        --set ports.healthProbe=63001 \
        --set ports.metrics=63002 \
        --values $RESOURCES_DIR/opentelemetry-telemetry-remote.yaml

    wait_rollout deployment/admission-controller
    wait_policyserver default

    # Verify hostNetwork enabled on both controller and PS
    assert_deployment_hostnetwork "app.kubernetes.io/name=admission-controller" "true"
    assert_deployment_hostnetwork "kubewarden/policy-server=default" "true"

    # Policy must still be active after the transition
    wait_for --for=condition="PolicyActive" clusteradmissionpolicy --all -A

    # Controller must NO longer have --enable-otel-sidecar flag
    kubectl get deployment -n $NAMESPACE admission-controller -o json \
        | jq -e '.spec.template.spec.containers[0].args | any(. == "--enable-otel-sidecar") | not'

    # Controller must NO longer have sidecar annotation
    kubectl get deployment -n $NAMESPACE admission-controller -o json \
        | jq -e '(.spec.template.metadata.annotations // {}) | has("sidecar.opentelemetry.io/inject") | not'

    # Controller must have the custom OTEL_EXPORTER_OTLP_ENDPOINT env var
    kubectl get deployment -n $NAMESPACE admission-controller -o json \
        | jq -e '.spec.template.spec.containers[0].env[] | select(.name == "OTEL_EXPORTER_OTLP_ENDPOINT")'

    # PS deployment must NOT have sidecar annotation
    kubectl get deployment -n $NAMESPACE -l 'kubewarden/policy-server=default' -o json \
        | jq -e 'all(.items[]; (.spec.template.metadata.annotations // {}) | has("sidecar.opentelemetry.io/inject") | not)'

    # PS container must have the custom OTEL_EXPORTER_OTLP_ENDPOINT env var
    kubectl get deployment -n $NAMESPACE -l 'kubewarden/policy-server=default' -o json \
        | jq -e '.items[0].spec.template.spec.containers[0].env[] | select(.name == "OTEL_EXPORTER_OTLP_ENDPOINT")'

    # Verify NO otc-container sidecar on pods
    kubectl get pods -n $NAMESPACE -l 'app.kubernetes.io/component in (controller,policy-server)' -o json \
        | jq -e 'all(.items[]; (.spec.initContainers + .spec.containers | map(.name) | contains(["otc-container"]) | not))'

    # Verify metrics ports exist on services
    kubectl get services -n $NAMESPACE policy-server-default -o json \
        | jq -e 'any(.spec.ports[]; .name == "metrics")'
    kubectl get services -n $NAMESPACE -l app.kubernetes.io/name=admission-controller -o json \
        | jq -e 'any(.items[].spec.ports[]; .name == "metrics")'
}

@test "$(tfile) HostNetwork: Policy evaluation and metrics with custom telemetry" {
    # Unprivileged pod should be accepted
    kubectl run pause-custom --image=rancher/pause:3.2
    wait_for pod pause-custom

    # Privileged pod should be rejected
    kubefail_privileged run pod-priv-custom --image=rancher/pause:3.2 --privileged

    # Generate metric data
    kubectl run pod-priv-custom-m --image=rancher/pause:3.2 --privileged 2>/dev/null || true
    kubectl delete pod pod-priv-custom-m --ignore-not-found --wait=false

    # Verify metrics arrive at the custom collector
    retry 'test $(get_metrics my-collector-collector | grep "kubewarden_policy_evaluations_total" | wc -l) -gt 0'
    retry 'test $(get_metrics my-collector-collector | grep "kubewarden_policy_total" | wc -l) -gt 0'
}

@test "$(tfile) HostNetwork: Disable hostNetwork — custom telemetry continues" {
    helmer set admission-controller --set hostNetwork=false
    wait_rollout deployment/admission-controller
    wait_policyserver default

    # Verify hostNetwork disabled
    assert_deployment_hostnetwork "app.kubernetes.io/name=admission-controller" "false"
    assert_deployment_hostnetwork "kubewarden/policy-server=default" "false"

    # Policy evaluation must still work
    kubectl run pause-post --image=rancher/pause:3.2
    wait_for pod pause-post

    kubefail_privileged run pod-priv-post --image=rancher/pause:3.2 --privileged

    # Generate fresh metric data
    kubectl run pod-priv-post-m --image=rancher/pause:3.2 --privileged 2>/dev/null || true
    kubectl delete pod pod-priv-post-m --ignore-not-found --wait=false

    # Verify metrics still arrive at the collector
    retry 'test $(get_metrics my-collector-collector | grep "kubewarden_policy_evaluations_total" | wc -l) -gt 0'
    retry 'test $(get_metrics my-collector-collector | grep "kubewarden_policy_total" | wc -l) -gt 0'

    delete_policy privileged-pod-policy.yaml
}
