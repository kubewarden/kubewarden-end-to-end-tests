mkfile_path := $(abspath $(lastword $(MAKEFILE_LIST)))
mkfile_dir := $(dir $(mkfile_path))
TESTS_DIR ?= $(mkfile_dir)tests
RESOURCES_DIR ?= $(mkfile_dir)resources
TIMEOUT ?= 5m
CONTROLLER_CHART ?= kubewarden/kubewarden-controller
NAMESPACE ?= kubewarden
K3D_VERSION ?= v5.0.0

KUBEWARDEN_HELM_REPO_NAME ?= kubewarden
KUBEWARDEN_CONTROLLER_CHART_RELEASE ?= kubewarden-controller
KUBEWARDEN_CONTROLLER_CHART_VERSION ?= $(shell helm search repo $(KUBEWARDEN_HELM_REPO_NAME)/kubewarden-controller --versions -o json | jq ".[0].version" | sed "s/\"//g")
KUBEWARDEN_CRDS_CHART_VERSION ?= $(shell helm search repo $(KUBEWARDEN_HELM_REPO_NAME)/kubewarden-crds --versions -o json | jq ".[0].version" | sed "s/\"//g")
KUBEWARDEN_CRDS_CHART_RELEASE ?= kubewarden-crds
CERT_MANAGER_VERSION ?= v1.5.3

CLUSTER_NAME ?= $(shell echo kubewarden-tests-$(KUBEWARDEN_CONTROLLER_CHART_VERSION) | sed 's/\./-/g')
CLUSTER_CONTEXT ?= k3d-$(CLUSTER_NAME)

kube = kubectl --context $(CLUSTER_CONTEXT) $(1)
bats = RESOURCES_DIR=$(RESOURCES_DIR) \
	TIMEOUT=$(TIMEOUT) \
	KUBEWARDEN_CONTROLLER_CHART_VERSION=$(KUBEWARDEN_CONTROLLER_CHART_VERSION) \
	KUBEWARDEN_CONTROLLER_CHART_RELEASE=$(KUBEWARDEN_CONTROLLER_CHART_RELEASE) \
	CONTROLLER_CHART=$(CONTROLLER_CHART) \
	CLUSTER_CONTEXT=$(CLUSTER_CONTEXT) \
	NAMESPACE=$(NAMESPACE) \
		bats \
		--verbose-run \
		--show-output-of-passing-tests \
		--print-output-on-failure \
		$(1)

install-k3d:
	curl -s https://raw.githubusercontent.com/rancher/k3d/main/install.sh | TAG=$(K3D_VERSION) bash

install-kubewarden-chart-repo:
	helm repo add --force-update $(KUBEWARDEN_HELM_REPO_NAME) https://charts.kubewarden.io

.PHONY: setup
setup: install-k3d install-kubewarden-chart-repo

.PHONY: install-cert-manager
install-cert-manager:
	$(call kube, apply -f https://github.com/jetstack/cert-manager/releases/download/$(CERT_MANAGER_VERSION)/cert-manager.yaml)
	$(call kube, wait --for=condition=Available deployment --timeout=$(TIMEOUT) -n cert-manager --all)

.PHONY: delete-k8s-cluster
delete-k8s-cluster:
	- k3d cluster delete $(CLUSTER_NAME)

.PHONY: create-k8s-cluster
create-k8s-cluster: delete-k8s-cluster
	k3d cluster create $(CLUSTER_NAME) --wait --timeout $(TIMEOUT) --config $(RESOURCES_DIR)/k3d-default.yaml -v /dev/mapper:/dev/mapper
	$(call kube,  wait --for=condition=Ready nodes --all)

.PHONY: install-kubewarden
install-kubewarden: install-cert-manager install-kubewarden-chart-repo
	helm upgrade --install --wait \
		--kube-context $(CLUSTER_CONTEXT) \
		--namespace $(NAMESPACE) --create-namespace \
		--version $(KUBEWARDEN_CRDS_CHART_VERSION) \
		$(KUBEWARDEN_CRDS_CHART_RELEASE) $(KUBEWARDEN_HELM_REPO_NAME)/kubewarden-crds
	helm upgrade --install --wait --namespace $(NAMESPACE) \
		--kube-context $(CLUSTER_CONTEXT) \
		--values $(RESOURCES_DIR)/default-kubewarden-controller-values.yaml \
		--version $(KUBEWARDEN_CONTROLLER_CHART_VERSION) \
		$(KUBEWARDEN_CONTROLLER_CHART_RELEASE) $(KUBEWARDEN_HELM_REPO_NAME)/kubewarden-controller
	$(call kube, wait --for=condition=Ready --namespace $(NAMESPACE) pods --all)

.PHONY: delete-kubewarden
delete-kubewarden:
	- helm --namespace $(NAMESPACE) \
		--kube-context $(CLUSTER_CONTEXT) \
		delete $(KUBEWARDEN_CONTROLLER_CHART_RELEASE)
	- helm --namespace $(NAMESPACE) \
		--kube-context $(CLUSTER_CONTEXT) \
		delete $(KUBEWARDEN_CRDS_CHART_RELEASE)

.PHONY: reconfiguration-test
reconfiguration-test:
	$(call bats, $(TESTS_DIR)/reconfiguration-tests.bats)

.PHONY: basic-e2e-test
basic-e2e-test:
	$(call bats, $(TESTS_DIR)/basic-end-to-end-tests.bats)

.PHONY: mutating-requests-test
mutating-requests-test:
	$(call bats, $(TESTS_DIR)/mutating-requests-tests.bats)

.PHONY: monitor-mode-test
monitor-mode-test:
	$(call bats, $(TESTS_DIR)/monitor-mode-tests.bats)

.PHONY: namespaced-admission-policy-test
namespaced-admission-policy-test:
	$(call bats, $(TESTS_DIR)/namespaced-admission-policy-tests.bats)
