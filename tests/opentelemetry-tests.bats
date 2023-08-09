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
    helm_up kubewarden-controller --reuse-values --values $RESOURCES_DIR/opentelemetry-kw-telemetry-values.yaml
    helm_up kubewarden-defaults --reuse-values --set "recommendedPolicies.enabled=True"

}

@test "[OpenTelemetry] Kubewarden containers have sidecars & metrics" {
    # Controller is restarted to get sidecar
    wait_pods -n kubewarden

    # Check all pods have sidecar (otc-container) - might take a minute to start
    retry "kubectl get pods -n kubewarden --field-selector=status.phase==Running -o json | jq -e '[.items[].spec.containers[1].name == \"otc-container\"] | all'"
    # Policy server service has the metrics ports
    kubectl get services -n kubewarden  policy-server-default -o json | jq -e '[.spec.ports[].name == "metrics"] | any'
    # Controller service has the metrics ports
    kubectl get services -n kubewarden kubewarden-controller-metrics-service -o json | jq -e '[.spec.ports[].name == "metrics"] | any'

    # Generate metric data
    kubectl run pod-privileged --image=registry.k8s.io/pause --privileged
    kubectl wait --for=condition=Ready pod pod-privileged
    kubectl delete --wait pod pod-privileged

    # Policy server metrics should be available
    test $(curlpod --silent policy-server-default.kubewarden.svc.cluster.local:8080/metrics | wc -l ) -gt 10
    # Controller metrics should be available
    test $(curlpod --silent kubewarden-controller-metrics-service.kubewarden.svc.cluster.local:8080/metrics | wc -l) -gt 1
}

@test "[OpenTelemetry] Audit scanner runs should generate metrics" {
    kubectl get cronjob -n $NAMESPACE audit-scanner

    # Launch unprivileged & privileged pods
    kubectl run nginx-unprivileged --image=nginx:alpine
    kubectl wait --for=condition=Ready pod nginx-unprivileged
    kubectl run nginx-privileged --image=registry.k8s.io/pause --privileged
    kubectl wait --for=condition=Ready pod nginx-privileged

    # Deploy some policy
    apply_cluster_admission_policy $RESOURCES_DIR/privileged-pod-policy.yaml
    apply_cluster_admission_policy $RESOURCES_DIR/namespace-label-propagator-policy.yaml

    run kubectl create job  --from=cronjob/audit-scanner testing  --namespace $NAMESPACE
    assert_output -p "testing created"
    kubectl wait --for=condition="Complete" job testing --namespace $NAMESPACE

    kubectl get clusterpolicyreports polr-clusterwide
    kubectl get policyreports polr-ns-default
    test $(curlpod --silent policy-server-default.kubewarden.svc.cluster.local:8080/metrics | grep protect | sed --silent  's/.*policy_name=\(.*\).*/\1/p' | sed 's/,.*//p' | sort -u | wc -l) -eq 2
}

@test "[OpenTelemetry] Disabling telemetry should remove sidecars & metrics" {
    helm_up kubewarden-controller --reuse-values --values $RESOURCES_DIR/opentelemetry-kw-telemetry-values.yaml --set "telemetry.enabled=False"
    helm_up kubewarden-defaults --reuse-values
    wait_pods -n kubewarden

    # Check sidecars (otc-container) - have been removed
    retry "kubectl get pods -n kubewarden -o json | jq -e '[.items[].spec.containers[1].name != \"otc-container\"] | all'"
    # Policy server service has no metrics ports
    kubectl get services -n kubewarden policy-server-default -o json | jq -e '[.spec.ports[].name != "metrics"] | all'
    # Controller service has no metrics ports
    kubectl get services -n kubewarden kubewarden-controller-metrics-service -o json | jq -e '[.spec.ports[].name != "metrics"] | all '
}

teardown_file() {
    kubectl delete -f $RESOURCES_DIR/privileged-pod-policy.yaml
    kubectl delete -f $RESOURCES_DIR/namespace-label-propagator-policy.yaml
    kubectl delete pod nginx-privileged nginx-unprivileged
    kubectl delete jobs -n kubewarden testing
}
