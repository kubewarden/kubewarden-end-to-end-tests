#!/usr/bin/env bats

# UI access:
# kubectl port-forward -n prometheus --address 0.0.0.0 svc/prometheus-operated 9090
# kubectl port-forward -n jaeger svc/my-open-telemetry-query 16686:16686

setup() {
  load common.bash
  wait_pods -n kube-system
}

@test "[OpenTelemetry] Install OpenTelemetry, Prometheus, Jaeger" {
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
    helm_in kubewarden-controller --reuse-values --values $RESOURCES_DIR/opentelemetry-kw-telemetry-values.yaml
    helm_in kubewarden-defaults --reuse-values --set "recommendedPolicies.enabled=True"

}

@test "[OpenTelemetry] Kubewarden containers have sidecar" {
    # Controller needs to be restarted to get sidecar
    wait_pods -n kubewarden

    # Check all pods have sidecar (otc-container) - might take a minute to start
    retry "kubectl get pods -n kubewarden -o json | jq -e '[.items[].spec.containers[1].name == \"otc-container\"] | all'"
}

@test "[OpenTelemetry] Policy server service has the metrics ports" {
	retry "kubectl get services -n kubewarden  policy-server-default -o json | jq -e '[.spec.ports[].name == \"metrics\"] | any '"
}

@test "[OpenTelemetry] Controller service has the metrics ports" {
	retry "kubectl get services -n kubewarden kubewarden-controller-metrics-service -o json | jq -e '[.spec.ports[].name == \"metrics\"] | any '"
}

@test "[OpenTelemetry] Policy server metrics should be available" {
    # Generate metric data
    kubectl run pod-privileged --image=registry.k8s.io/pause --privileged
    retry "[ \$(kubectl run get-policy-server-metric -t -i --rm --wait --image curlimages/curl:8.00.1 --restart=Never -- --silent policy-server-default.kubewarden.svc.cluster.local:8080/metrics | wc -l ) -gt 10 ] || exit 1"
}

@test "[OpenTelemetry] Controller metrics should be available" {
    retry "[ \$(kubectl run get-controller-metric -t -i --rm --wait --image curlimages/curl:8.00.1 --restart=Never -- --silent kubewarden-controller-metrics-service.kubewarden.svc.cluster.local:8080/metrics | wc -l) -gt 1 ] || exit 1"
}

@test "[OpenTelemetry] User should be able to disable telemetry" {
    helm_in kubewarden-controller --reuse-values --values $RESOURCES_DIR/opentelemetry-kw-telemetry-values.yaml --set "telemetry.enabled=False"
    helm_in kubewarden-defaults --reuse-values
}

@test "[OpenTelemetry] Kubewarden containers have no sidecar" {
    # Controller needs to be restarted to get sidecar
    wait_pods -n kubewarden

    # Check sidecars (otc-container) - have been removed
    retry "kubectl get pods -n kubewarden -o json | jq -e '[.items[].spec.containers[1].name != \"otc-container\"] | all'"
}

@test "[OpenTelemetry] Policy server service has no metrics ports" {
	retry "kubectl get services -n kubewarden  policy-server-default -o json | jq -e '[.spec.ports[].name != \"metrics\"] | all '"
}

@test "[OpenTelemetry] Controller service has no metrics ports" {
	retry "kubectl get services -n kubewarden kubewarden-controller-metrics-service -o json | jq -e '[.spec.ports[].name != \"metrics\"] | all '"
}
