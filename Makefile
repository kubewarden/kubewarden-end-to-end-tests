.DEFAULT_GOAL := basic-end-to-end-tests.bats

mkfile_path := $(abspath $(lastword $(MAKEFILE_LIST)))
mkfile_dir := $(dir $(mkfile_path))
TESTS_DIR ?= $(mkfile_dir)tests
# directory with all the "template" files used to generated the files used during
# the tests.
ROOT_RESOURCES_DIR ?= $(mkfile_dir)resources
# timeout for the kubectl commands
TIMEOUT ?= 5m
CONTROLLER_CHART ?= kubewarden/kubewarden-controller
NAMESPACE ?= kubewarden
K3D_VERSION ?= v5.4.4
# helm repo name used to download the Helm charts.
KUBEWARDEN_HELM_REPO_NAME ?= kubewarden
# URL where the Helm charts are stored
KUBEWARDEN_HELM_REPO_URL ?= https://charts.kubewarden.io
# The KUBEWARDEN_CHARTS_LOCATION variable define where charts live. By default, the Helm
# chart repository is used. However, if you want to test a local Helm chart
# version, you can overwrite this variable with the parent directory of the chart.
# But the chart name must be equal of the names in the Helm chart repository.
KUBEWARDEN_CHARTS_LOCATION ?= kubewarden

KUBEWARDEN_CONTROLLER_CHART_VERSION ?= $(shell helm search repo $(KUBEWARDEN_HELM_REPO_NAME)/$(KUBEWARDEN_CONTROLLER_CHART_RELEASE) --versions -o json --devel | jq -r ".[0].version")
KUBEWARDEN_CONTROLLER_CHART_OLD_VERSION ?= $(shell helm search repo $(KUBEWARDEN_HELM_REPO_NAME)/$(KUBEWARDEN_CONTROLLER_CHART_RELEASE) --versions -o json --devel | jq -r ".[1].version")
KUBEWARDEN_CONTROLLER_CHART_RELEASE ?= kubewarden-controller
KUBEWARDEN_CRDS_CHART_VERSION ?= $(shell helm search repo $(KUBEWARDEN_HELM_REPO_NAME)/$(KUBEWARDEN_CRDS_CHART_RELEASE) --versions -o json --devel | jq -r ".[0].version")
KUBEWARDEN_CRDS_CHART_OLD_VERSION ?= $(shell helm search repo $(KUBEWARDEN_HELM_REPO_NAME)/$(KUBEWARDEN_CRDS_CHART_RELEASE) --versions -o json --devel | jq -r ".[1].version")
KUBEWARDEN_CRDS_CHART_RELEASE ?= kubewarden-crds
KUBEWARDEN_DEFAULTS_CHART_VERSION ?= $(shell helm search repo $(KUBEWARDEN_HELM_REPO_NAME)/$(KUBEWARDEN_DEFAULTS_CHART_RELEASE) --versions -o json --devel | jq -r ".[0].version")
KUBEWARDEN_DEFAULTS_CHART_OLD_VERSION ?= $(shell helm search repo $(KUBEWARDEN_HELM_REPO_NAME)/$(KUBEWARDEN_DEFAULTS_CHART_RELEASE) --versions -o json --devel | jq -r ".[1].version")
KUBEWARDEN_DEFAULTS_CHART_RELEASE ?= kubewarden-defaults
CERT_MANAGER_VERSION ?= v1.11.0
#
# CRD version to be tested
CRD_VERSION ?= $(shell helm show values $(KUBEWARDEN_HELM_REPO_NAME)/$(KUBEWARDEN_DEFAULTS_CHART_RELEASE) --version $(KUBEWARDEN_DEFAULTS_CHART_VERSION) | yq -r ".crdVersion")
CRD_VERSION_SUFFIX ?= $(shell echo $(CRD_VERSION) | cut -d'/' -f2)
# directory with all the files used during the tests. This files are copied from
# $(ROOT_RESOURCES_DIR) and changed to used the CRDs version defined in $(CRD_VERSION)
RESOURCES_DIR ?= $(ROOT_RESOURCES_DIR)/resources_$(CRD_VERSION_SUFFIX)

export CLUSTER_NAME ?= kubewarden-testing
CLUSTER_CONTEXT ?= k3d-$(CLUSTER_NAME)

# ==================================================================================================
# Aliases
kube = kubectl --context $(CLUSTER_CONTEXT) $(1)
helm = helm --kube-context $(CLUSTER_CONTEXT) $(1)
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
		bats --print-output-on-failure $(1)

helm_in = $(helm) upgrade --install --wait --namespace $(NAMESPACE) --create-namespace

# ==================================================================================================
# Macros
define install-kubewarden =
	helm repo add --force-update $(KUBEWARDEN_HELM_REPO_NAME) $(KUBEWARDEN_HELM_REPO_URL)
	$(helm_in) --version $(KUBEWARDEN_CRDS_CHART_VERSION) \
		$(KUBEWARDEN_CRDS_CHART_RELEASE) $(KUBEWARDEN_CHARTS_LOCATION)/kubewarden-crds
	$(helm_in) --version $(KUBEWARDEN_CONTROLLER_CHART_VERSION) \
		--values $(ROOT_RESOURCES_DIR)/default-kubewarden-controller-values.yaml \
		$(KUBEWARDEN_CONTROLLER_CHART_RELEASE) $(KUBEWARDEN_CHARTS_LOCATION)/kubewarden-controller
	$(helm_in) --version $(KUBEWARDEN_DEFAULTS_CHART_VERSION) \
		--values $(ROOT_RESOURCES_DIR)/default-kubewarden-defaults-values.yaml \
		$(KUBEWARDEN_DEFAULTS_CHART_RELEASE) $(KUBEWARDEN_CHARTS_LOCATION)/kubewarden-defaults
	$(kube) wait --for=condition=Ready --namespace $(NAMESPACE) pods --all
endef

define install-cert-manager =
	$(kube) apply -f https://github.com/cert-manager/cert-manager/releases/download/$(CERT_MANAGER_VERSION)/cert-manager.yaml
	$(kube) wait --for=condition=Available deployment --timeout=2m -n cert-manager --all
endef

define generate-versioned-resources-dir =
	./scripts/generate_resources_dir.sh $(ROOT_RESOURCES_DIR) $(CRD_VERSION)
endef

# ==================================================================================================
# Targets

# Upgrade test requires new cluster
upgrade.bats:: clean cluster
	$(install-cert-manager)

# Generate target for every test file
TESTS := $(notdir $(wildcard tests/*.bats))
$(TESTS)::
	$(generate-versioned-resources-dir)
	$(call bats, $(TESTS_DIR)/$@)

# Target all non-destructive tests
.PHONY: tests
tests: $(filter-out upgrade.bats, $(TESTS))

.PHONY: cluster install reinstall clean

cluster:
	k3d cluster create $(CLUSTER_NAME) -s 1 -a 1 --wait --timeout $(TIMEOUT) -v /dev/mapper:/dev/mapper --image rancher/k3s:v1.24.12-k3s1
	$(kube) wait --for=condition=Ready nodes --all

install:
	$(install-cert-manager)
	$(install-kubewarden)

clean:
	k3d cluster delete $(CLUSTER_NAME)

reinstall: clean cluster install
