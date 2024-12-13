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

    # Remove installed apps
    helm uninstall --wait -n jaeger jaeger-operator
    helm uninstall --wait -n prometheus prometheus
    helm uninstall --wait -n open-telemetry my-opentelemetry-operator
    helm uninstall --wait -n cert-manager cert-manager

    helmer reset controller
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

@test "[Remote OpenTelemetry collector] Install OpenTelemetry, Prometheus, Jaeger" {
    # Required by OpenTelemetry
    helm repo add jetstack https://charts.jetstack.io --force-update
    helm upgrade -i --wait cert-manager jetstack/cert-manager \
        -n cert-manager --create-namespace \
        --set crds.enabled=true

    # OpemTelementry
    helm repo add --force-update open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
    helm upgrade -i --wait my-opentelemetry-operator open-telemetry/opentelemetry-operator \
        --set "manager.collectorImage.repository=otel/opentelemetry-collector-contrib" \
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

    kubectl apply -f $RESOURCES_DIR/opentelemetry-jaeger.yaml
    wait_pods -n jaeger

    kubectl apply --namespace $NAMESPACE -f $RESOURCES_DIR/otel-collector-deployment.yaml
    wait_pods -n $NAMESPACE

    # Setup Kubewarden
    helmer set kubewarden-controller --values $RESOURCES_DIR/opentelemetry-telemetry-remote.yaml
    helmer set kubewarden-defaults --set recommendedPolicies.enabled=True
}

@test "[Remote OpenTelemetry collector] Kubewarden containers send metrics to remote Otel collector" {
    # Controller is restarted to get sidecar
    wait_pods -n $NAMESPACE

    # Generate metric data
    kubectl run pod-privileged --image=registry.k8s.io/pause --privileged
    kubectl wait --for=condition=Ready pod pod-privileged
    kubectl delete --wait pod pod-privileged

    retry 'test $(get_metrics my-collector-collector | grep "kubewarden_policy_total" | wc -l) -gt 1'
    retry 'test $(get_metrics my-collector-collector | grep "kubewarden_policy_evaluations_total" | wc -l) -gt 1'
}
