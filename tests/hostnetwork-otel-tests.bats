#!/usr/bin/env bats

# Tests hostNetwork combined with OTel telemetry mode transitions.
# The chart and controller reject hostNetwork + sidecar mode as incompatible,
# so this test validates the supported transition path:
#
# Flow:
#   1. Install OTel stack (cert-manager, OTel Operator, Prometheus, Jaeger)
#      + standalone collector in deployment mode
#   2. Enable sidecar telemetry (hostNetwork=false) — verify sidecar baseline,
#      policy evaluation, and metrics
#   3. Switch to custom telemetry + enable hostNetwork in one upgrade — verify
#      sidecar artifacts removed, custom env set, policy survives
#   4. Policy evaluation + metrics at custom collector
#   5. Disable hostNetwork — custom telemetry continues, policy eval + metrics
#
# Port allocation:
#   Controller: webhook=63000 healthProbe=63001 metrics=63002
#   Default PS host ports: webhookPort=64005 readinessProbePort=63003
#     (metricsPort=63004 is a Service-layer setting only — it changes what port
#      Prometheus scrapes on the Service, NOT the port the pod binds on the host)

setup() {
    setup_helper
    load "../helpers/hostnetwork.sh"
}

teardown_file() {
    teardown_helper

    # Remove standalone collector
    kubectl delete --ignore-not-found --namespace $NAMESPACE -f $RESOURCES_DIR/otel-collector-deployment.yaml

    # Remove OTel stack
    kubectl delete --ignore-not-found -f $RESOURCES_DIR/opentelemetry-jaeger.yaml
    helm uninstall --wait -n jaeger jaeger-operator 2>/dev/null || true
    helm uninstall --wait -n prometheus prometheus 2>/dev/null || true
    helm uninstall --wait -n open-telemetry my-opentelemetry-operator 2>/dev/null || true
    helm uninstall --wait -n cert-manager cert-manager 2>/dev/null || true

    # Reset Kubewarden to defaults
    helmer reset kubewarden-controller
    helmer reset kubewarden-defaults
}


@test "$(tfile) Install OTel stack and standalone collector" {
    # cert-manager (required by OTel Operator)
    helm repo add e2e-jetstack https://charts.jetstack.io --force-update
    helm upgrade -i --wait cert-manager e2e-jetstack/cert-manager \
        -n cert-manager --create-namespace \
        --set crds.enabled=true

    # OpenTelemetry Operator
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
    retry "kuberun wget -O- https://jaeger-operator-webhook-service.jaeger.svc/mutate-jaegertracing-io-v1-jaeger" 2 10

    kubectl apply -f $RESOURCES_DIR/opentelemetry-jaeger.yaml
    wait_pods -n jaeger

    # Deploy standalone OTel collector (deployment mode)
    kubectl apply --namespace $NAMESPACE -f $RESOURCES_DIR/otel-collector-deployment.yaml
    wait_pods -n $NAMESPACE
}

# --- Phase 1: Sidecar telemetry baseline (hostNetwork=false) ---

@test "$(tfile) Enable sidecar telemetry and verify baseline" {
    # Enable sidecar telemetry WITHOUT hostNetwork.
    # Pre-set custom ports on defaults in preparation for later hostNetwork use.
    helmer set kubewarden-defaults \
        --set policyServer.replicaCount=1 \
        --set policyServer.readinessProbePort=63003 \
        --set policyServer.metricsPort=63004 \
        --set policyServer.webhookPort=64005

    helmer set kubewarden-controller \
        --values $RESOURCES_DIR/opentelemetry-telemetry.yaml

    wait_rollout deployment/kubewarden-controller
    wait_policyserver default

    # Verify hostNetwork is NOT enabled
    assert_deployment_hostnetwork "app.kubernetes.io/name=kubewarden-controller" "false"
    assert_deployment_hostnetwork "kubewarden/policy-server=default" "false"

    # Verify otc-container sidecar IS running on pods
    retry "kubectl get pods -n $NAMESPACE -l 'app.kubernetes.io/component in (controller,policy-server)' -o json \
        | jq -e 'all(.items[]; (.spec.initContainers[]?, .spec.containers[]) | select(.name == \"otc-container\"))'"

    # Verify sidecar annotation on controller deployment
    kubectl get deployment -n $NAMESPACE kubewarden-controller -o json \
        | jq -e '.spec.template.metadata.annotations["sidecar.opentelemetry.io/inject"] == "true"'

    # Verify --enable-otel-sidecar flag in controller args
    kubectl get deployment -n $NAMESPACE kubewarden-controller -o json \
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


# --- Phase 2: Sidecar → custom telemetry + hostNetwork transition ---

@test "$(tfile) Switch to custom telemetry and enable hostNetwork" {
    # Combined transition: sidecar → custom telemetry AND hostNetwork=false → true
    # in a single Helm upgrade.
    helmer set kubewarden-controller --set hostNetwork=true \
        --set ports.webhook=63000 \
        --set ports.healthProbe=63001 \
        --set ports.metrics=63002 \
        --values $RESOURCES_DIR/opentelemetry-telemetry-remote.yaml

    wait_rollout deployment/kubewarden-controller
    wait_policyserver default

    # Verify hostNetwork enabled on both controller and PS
    assert_deployment_hostnetwork "app.kubernetes.io/name=kubewarden-controller" "true"
    assert_deployment_hostnetwork "kubewarden/policy-server=default" "true"

    # Policy must still be active after the transition
    wait_for --for=condition="PolicyActive" clusteradmissionpolicy --all -A

    # Controller must NO longer have --enable-otel-sidecar flag
    kubectl get deployment -n $NAMESPACE kubewarden-controller -o json \
        | jq -e '.spec.template.spec.containers[0].args | any(. == "--enable-otel-sidecar") | not'

    # Controller must NO longer have sidecar annotation
    kubectl get deployment -n $NAMESPACE kubewarden-controller -o json \
        | jq -e '(.spec.template.metadata.annotations // {}) | has("sidecar.opentelemetry.io/inject") | not'

    # Controller must have the custom OTEL_EXPORTER_OTLP_ENDPOINT env var
    kubectl get deployment -n $NAMESPACE kubewarden-controller -o json \
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
    kubectl get services -n $NAMESPACE -l app.kubernetes.io/name=kubewarden-controller -o json \
        | jq -e 'any(.items[].spec.ports[]; .name == "metrics")'
}


@test "$(tfile) Policy evaluation and metrics with custom telemetry" {
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


# --- Phase 3: Disable hostNetwork — custom telemetry continues ---

@test "$(tfile) Disable hostNetwork — custom telemetry continues" {
    helmer set kubewarden-controller --set hostNetwork=false
    wait_rollout deployment/kubewarden-controller
    wait_policyserver default

    # Verify hostNetwork disabled
    assert_deployment_hostnetwork "app.kubernetes.io/name=kubewarden-controller" "false"
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
