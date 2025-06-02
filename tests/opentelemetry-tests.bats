#!/usr/bin/env bats

# UI access:
# kubectl port-forward -n prometheus --address 0.0.0.0 svc/prometheus-operated 9090
# kubectl port-forward -n jaeger svc/my-open-telemetry-query 16686:16686

setup() {
    load ../helpers/helpers.sh
    wait_pods -n kube-system
}

teardown_file() {
    load ../helpers/helpers.sh
    kubectl delete admissionpolicies,clusteradmissionpolicies --all -A
    kubectl delete pod nginx-privileged nginx-unprivileged --ignore-not-found

    # Remote otel collector cleanup
    kubectl delete --ignore-not-found -f $RESOURCES_DIR/opentelemetry-jaeger.yaml
    kubectl delete --ignore-not-found --namespace $NAMESPACE -f $RESOURCES_DIR/otel-collector-deployment.yaml

    # Remove installed apps
    helm uninstall --wait -n jaeger jaeger-operator
    helm uninstall --wait -n prometheus prometheus
    helm uninstall --wait -n open-telemetry my-opentelemetry-operator
    helm uninstall --wait -n cert-manager cert-manager

    helmer reset controller
    helmer reset kubewarden-defaults
}

# get_metrics policy-server-default
function get_metrics {
    pod=$1
    ns=${2:-$NAMESPACE}

    kubectl delete pod curlpod --ignore-not-found
    kubectl run curlpod -t -i --rm --image curlimages/curl:8.10.1 --restart=Never -- \
        --silent $pod.$ns.svc.cluster.local:8080/metrics
}
export -f get_metrics # required by retry command

@test "[OpenTelemetry] Install OpenTelemetry, Prometheus, Jaeger" {
    # Required by OpenTelemetry
    helm repo add e2e-jetstack https://charts.jetstack.io --force-update
    helm upgrade -i --wait cert-manager e2e-jetstack/cert-manager \
        -n cert-manager --create-namespace \
        --set crds.enabled=true

    # OpemTelementry
    helm repo add --force-update open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
    # v0.86.4 - https://github.com/open-telemetry/opentelemetry-helm-charts/issues/1648
    helm upgrade -i --wait my-opentelemetry-operator open-telemetry/opentelemetry-operator \
        --set "manager.collectorImage.repository=otel/opentelemetry-collector-contrib" \
        --version "${OTEL_OPERATOR:-0.86.4}" \
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
    helmer set kubewarden-controller --values $RESOURCES_DIR/opentelemetry-telemetry.yaml
    helmer set kubewarden-defaults --set recommendedPolicies.enabled=True
}

@test "[OpenTelemetry] Kubewarden containers have sidecars & metrics" {
    # Controller is restarted to get sidecar
    wait_pods -n $NAMESPACE

    # Check all pods have sidecar (otc-container) - might take a minute to start
    retry "kubectl get pods -n kubewarden --field-selector=status.phase==Running -o json | jq -e '[.items[].spec.containers[1].name == \"otc-container\"] | all'"
    # Policy server service has the metrics ports
    kubectl get services -n $NAMESPACE  policy-server-default -o json | jq -e '[.spec.ports[].name == "metrics"] | any'
    # Controller service has the metrics ports
    kubectl get services -n $NAMESPACE kubewarden-controller-metrics-service -o json | jq -e '[.spec.ports[].name == "metrics"] | any'

    # Generate metric data
    kubectl run pod-privileged --image=rancher/pause:3.2 --privileged
    wait_for pod pod-privileged
    kubectl delete --wait pod pod-privileged

    # Policy server & controller metrics should be available
    retry 'test $(get_metrics policy-server-default | wc -l) -gt 10'
    retry 'test $(get_metrics kubewarden-controller-metrics-service | wc -l) -gt 1'
}

@test "[OpenTelemetry] Audit scanner runs should generate metrics" {
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

@test "[OpenTelemetry] Disabling telemetry should remove sidecars & metrics" {
    helmer set kubewarden-controller \
        --set telemetry.metrics=False \
        --set telemetry.tracing=False
    helmer set kubewarden-defaults --set recommendedPolicies.enabled=False
    wait_pods -n $NAMESPACE

    # Check sidecars (otc-container) - have been removed
    retry "kubectl get pods -n kubewarden -o json | jq -e '[.items[].spec.containers[1].name != \"otc-container\"] | all'"
    # Policy server service has no metrics ports
    kubectl get services -n $NAMESPACE policy-server-default -o json | jq -e '[.spec.ports[].name != "metrics"] | all'
    # Controller service has no metrics ports
    kubectl get services -n $NAMESPACE kubewarden-controller-metrics-service -o json | jq -e '[.spec.ports[].name != "metrics"] | all'
}

@test "[OpenTelemetry Remote collector] Setup remote Otel collector" {
    kubectl apply --namespace $NAMESPACE -f $RESOURCES_DIR/otel-collector-deployment.yaml
    wait_pods -n $NAMESPACE

    helmer set kubewarden-controller --values $RESOURCES_DIR/opentelemetry-telemetry-remote.yaml
    helmer set kubewarden-defaults --set recommendedPolicies.enabled=True
    wait_pods -n $NAMESPACE
}

@test "[OpenTelemetry Remote collector] Metrics are sent to remote Otel collector" {
    # Generate metric data
    kubectl run pod-privileged --image=rancher/pause:3.2 --privileged
    wait_for pod pod-privileged
    kubectl delete --wait pod pod-privileged

    retry 'test $(get_metrics my-collector-collector | grep "kubewarden_policy_total" | wc -l) -gt 1'
    retry 'test $(get_metrics my-collector-collector | grep "kubewarden_policy_evaluations_total" | wc -l) -gt 1'
}
