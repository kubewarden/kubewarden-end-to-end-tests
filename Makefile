mkfile_path := $(abspath $(lastword $(MAKEFILE_LIST)))
mkfile_dir := $(dir $(mkfile_path))
TESTS_DIR ?= $(mkfile_dir)tests
# directory with all the "template" files used to generated the files used during
# the tests.
ROOT_RESOURCES_DIR ?= $(mkfile_dir)resources
# directory with all the files used during the tests. This files are copied from
# $(ROOT_RESOURCES_DIR) and changed to used the CRDs version defined in $(CRD_VERSION)
RESOURCES_DIR ?= $(ROOT_RESOURCES_DIR)/resources_$(CRD_VERSION)
# CRD version to be tested
CRD_VERSION ?= v1alpha2
# timeout for the kubectl commands
TIMEOUT ?= 5m
CONTROLLER_CHART ?= kubewarden/kubewarden-controller
NAMESPACE ?= kubewarden
K3D_VERSION ?= v5.0.0
# helm repo name used to download the Helm charts.
KUBEWARDEN_HELM_REPO_NAME ?= kubewarden
# URL where the Helm charts are stored
KUBEWARDEN_HELM_REPO_URL ?= https://charts.kubewarden.io
# The KUBEWARDEN_CHARTS_LOCATION variable define where charts live. By default, the Helm
# chart repository is used. However, if you want to test a local Helm chart
# version, you can overwrite this variable with the parent directory of the chart.
# But the chart name must be equal of the names in the Helm chart repository.
KUBEWARDEN_CHARTS_LOCATION ?= kubewarden

KUBEWARDEN_CONTROLLER_CHART_VERSION ?= $(shell helm search repo $(KUBEWARDEN_HELM_REPO_NAME)/$(KUBEWARDEN_CONTROLLER_CHART_RELEASE) --versions -o json | jq ".[0].version" | sed "s/\"//g")
KUBEWARDEN_CONTROLLER_CHART_OLD_VERSION ?= $(shell helm search repo $(KUBEWARDEN_HELM_REPO_NAME)/$(KUBEWARDEN_CONTROLLER_CHART_RELEASE) --versions -o json | jq ".[1].version" | sed "s/\"//g")
KUBEWARDEN_CONTROLLER_CHART_RELEASE ?= kubewarden-controller
KUBEWARDEN_CRDS_CHART_VERSION ?= $(shell helm search repo $(KUBEWARDEN_HELM_REPO_NAME)/$(KUBEWARDEN_CRDS_CHART_RELEASE) --versions -o json | jq ".[0].version" | sed "s/\"//g")
KUBEWARDEN_CRDS_CHART_OLD_VERSION ?= $(shell helm search repo $(KUBEWARDEN_HELM_REPO_NAME)/$(KUBEWARDEN_CRDS_CHART_RELEASE) --versions -o json | jq ".[1].version" | sed "s/\"//g")
KUBEWARDEN_CRDS_CHART_RELEASE ?= kubewarden-crds
KUBEWARDEN_DEFAULTS_CHART_VERSION ?= $(shell helm search repo $(KUBEWARDEN_HELM_REPO_NAME)/$(KUBEWARDEN_DEFAULTS_CHART_RELEASE) --versions -o json | jq ".[0].version" | sed "s/\"//g")
KUBEWARDEN_DEFAULTS_CHART_OLD_VERSION ?= $(shell helm search repo $(KUBEWARDEN_HELM_REPO_NAME)/$(KUBEWARDEN_DEFAULTS_CHART_RELEASE) --versions -o json | jq ".[1].version" | sed "s/\"//g")
KUBEWARDEN_DEFAULTS_CHART_RELEASE ?= kubewarden-defaults
CERT_MANAGER_VERSION ?= v1.5.3

CLUSTER_NAME ?= kubewarden-testing #$(shell echo kubewarden-tests-$(KUBEWARDEN_CONTROLLER_CHART_VERSION) | sed 's/\./-/g')
CLUSTER_CONTEXT ?= k3d-$(CLUSTER_NAME)

kube = kubectl --context $(CLUSTER_CONTEXT) $(1)
bats = RESOURCES_DIR=$(RESOURCES_DIR) \
	TIMEOUT=$(TIMEOUT) \
	KUBEWARDEN_CRDS_CHART_OLD_VERSION=$(KUBEWARDEN_CRDS_CHART_OLD_VERSION) \
	KUBEWARDEN_DEFAULTS_CHART_OLD_VERSION=$(KUBEWARDEN_DEFAULTS_CHART_OLD_VERSION) \
	KUBEWARDEN_CONTROLLER_CHART_OLD_VERSION=$(KUBEWARDEN_CONTROLLER_CHART_OLD_VERSION) \
	KUBEWARDEN_CRDS_CHART_VERSION=$(KUBEWARDEN_CRDS_CHART_VERSION) \
	KUBEWARDEN_DEFAULTS_CHART_VERSION=$(KUBEWARDEN_DEFAULTS_CHART_VERSION) \
	KUBEWARDEN_CONTROLLER_CHART_VERSION=$(KUBEWARDEN_CONTROLLER_CHART_VERSION) \
	KUBEWARDEN_CONTROLLER_CHART_RELEASE=$(KUBEWARDEN_CONTROLLER_CHART_RELEASE) \
	KUBEWARDEN_CHARTS_LOCATION=$(KUBEWARDEN_CHARTS_LOCATION) \
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
	helm repo add --force-update $(KUBEWARDEN_HELM_REPO_NAME) $(KUBEWARDEN_HELM_REPO_URL)

.PHONY: generate-versioned-resources-dir
generate-versioned-resources-dir:
	./scripts/generate_resources_dir.sh $(ROOT_RESOURCES_DIR) $(CRD_VERSION)

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
	k3d cluster create $(CLUSTER_NAME) --wait --timeout $(TIMEOUT) --config $(ROOT_RESOURCES_DIR)/k3d-default.yaml -v /dev/mapper:/dev/mapper
	$(call kube,  wait --for=condition=Ready nodes --all)

.PHONY: install-kubewarden
install-kubewarden: install-cert-manager install-kubewarden-chart-repo
	helm upgrade --install --wait \
		--kube-context $(CLUSTER_CONTEXT) \
		--namespace $(NAMESPACE) --create-namespace \
		$(KUBEWARDEN_CRDS_CHART_RELEASE) $(KUBEWARDEN_CHARTS_LOCATION)/kubewarden-crds
	helm upgrade --install --wait --namespace $(NAMESPACE) \
		--kube-context $(CLUSTER_CONTEXT) \
		--values $(ROOT_RESOURCES_DIR)/default-kubewarden-controller-values.yaml \
		$(KUBEWARDEN_CONTROLLER_CHART_RELEASE) $(KUBEWARDEN_CHARTS_LOCATION)/kubewarden-controller
	helm upgrade --install --wait --namespace $(NAMESPACE) \
		--kube-context $(CLUSTER_CONTEXT) \
		--values $(ROOT_RESOURCES_DIR)/default-kubewarden-defaults-values.yaml \
		$(KUBEWARDEN_DEFAULTS_CHART_RELEASE) $(KUBEWARDEN_CHARTS_LOCATION)/kubewarden-defaults
	$(call kube, wait --for=condition=Ready --namespace $(NAMESPACE) pods --all)

.PHONY: delete-kubewarden
delete-kubewarden:
	- helm --namespace $(NAMESPACE) \
		--kube-context $(CLUSTER_CONTEXT) \
		delete $(KUBEWARDEN_DEFAULTS_CHART_RELEASE)
	- helm --namespace $(NAMESPACE) \
		--kube-context $(CLUSTER_CONTEXT) \
		delete $(KUBEWARDEN_CONTROLLER_CHART_RELEASE)
	- helm --namespace $(NAMESPACE) \
		--kube-context $(CLUSTER_CONTEXT) \
		delete $(KUBEWARDEN_CRDS_CHART_RELEASE)

.PHONY: delete-opentelemetry
delete-opentelemetry:
	$(call kube, delete -f https://github.com/open-telemetry/opentelemetry-operator/releases/latest/download/opentelemetry-operator.yaml)

.PHONY: install-opentelemetry
install-opentelemetry: install-cert-manager
	$(call kube, apply -f https://github.com/open-telemetry/opentelemetry-operator/releases/latest/download/opentelemetry-operator.yaml)
	$(call kube, wait --for=condition=Available deployment --timeout=$(TIMEOUT) -n opentelemetry-operator-system --all)

.PHONY: reconfiguration-test
reconfiguration-test: generate-versioned-resources-dir
	$(call bats, $(TESTS_DIR)/reconfiguration-tests.bats)

.PHONY: basic-e2e-test
basic-e2e-test: generate-versioned-resources-dir
	$(call bats, $(TESTS_DIR)/basic-end-to-end-tests.bats)

.PHONY: mutating-requests-test
mutating-requests-test: generate-versioned-resources-dir
	$(call bats, $(TESTS_DIR)/mutating-requests-tests.bats)

.PHONY: monitor-mode-test
monitor-mode-test: generate-versioned-resources-dir
	$(call bats, $(TESTS_DIR)/monitor-mode-tests.bats)

.PHONY: namespaced-admission-policy-test
namespaced-admission-policy-test: generate-versioned-resources-dir
	$(call bats, $(TESTS_DIR)/namespaced-admission-policy-tests.bats)

.PHONY: secure-supply-chain-test
secure-supply-chain-test: generate-versioned-resources-dir
	$(call bats, $(TESTS_DIR)/secure-supply-chain-tests.bats)

.PHONY: upgrade-test
upgrade-test: create-k8s-cluster install-kubewarden-chart-repo install-cert-manager 
	rm -rf $(RESOURCES_DIR)
	mkdir $(RESOURCES_DIR)
	find $(ROOT_RESOURCES_DIR) -maxdepth 1 -type f  -exec cp \{\}  $(RESOURCES_DIR) \;
	$(call bats, $(TESTS_DIR)/upgrade.bats)
