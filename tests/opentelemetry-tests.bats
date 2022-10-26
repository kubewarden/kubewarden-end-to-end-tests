#!/usr/bin/env bats

# UI access:
# kubectl port-forward -n prometheus --address 0.0.0.0 svc/prometheus-operated 9090
# kubectl port-forward -n jaeger svc/my-open-telemetry-query 16686:16686

setup() {
  load common.bash
  wait_pods -n kube-system
}

@test "[OpenTelemetry] Install OpenTelemetry, Prometheus, Jaeger" {
    kubectl apply -f https://github.com/jetstack/cert-manager/releases/download/v1.9.1/cert-manager.yaml
    kubectl wait --for=condition=Available deployment --timeout=2m -n cert-manager --all
    
    # OpemTelementry
    helm repo add --force-update open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
    helm upgrade -i --wait my-opentelemetry-operator open-telemetry/opentelemetry-operator \
        -n open-telemetry --create-namespace

    # Prometheus
    helm repo add --force-update prometheus-community https://prometheus-community.github.io/helm-charts
    helm upgrade -i --wait  prometheus prometheus-community/kube-prometheus-stack \
        -n prometheus --create-namespace \
        --values $RESOURCES_DIR/opentelemetry-prometheus-values.yaml

    # Jaeger
    helm repo add --force-update jaegertracing https://jaegertracing.github.io/helm-charts
    helm upgrade -i --wait jaeger-operator jaegertracing/jaeger-operator \
        -n jaeger --create-namespace \
        --set rbac.clusterRole=true
    kubectl apply -f $RESOURCES_DIR/opentelemetry-jaeger.yaml
    wait_pods -n jaeger

    # Setup Kubewarden
    helm_in kubewarden-controller --values $RESOURCES_DIR/opentelemetry-kw-telemetry-values.yaml
    helm_in kubewarden-defaults \
      --set recommendedPolicies.enabled=True \
      --set policyServer.telemetry.enabled=True
}

@test "[OpenTelemetry] Kubewarden containers have sidecar" {
    # Controller needs to be restarted to get sidecar
    kubectl delete pod -n kubewarden -l app.kubernetes.io/name=kubewarden-controller
    wait_pods -n kubewarden

    # Check all pods have sidecar (otc-container)
    kubectl get pods -n kubewarden -o json | jq -e '[.items[].spec.containers[1].name == "otc-container"] | all'
}
