.DEFAULT_GOAL := basic-end-to-end-tests.bats

mkfile_path := $(abspath $(lastword $(MAKEFILE_LIST)))
mkfile_dir := $(dir $(mkfile_path))
TESTS_DIR ?= $(mkfile_dir)tests
# directory with all the "template" files used to generated the files used during the tests
ROOT_RESOURCES_DIR ?= $(mkfile_dir)resources

# Kubewarden helm repository
KUBEWARDEN_HELM_REPO_NAME ?= kubewarden
# Override to use kubewarden charts from local directory
KUBEWARDEN_CHARTS_LOCATION ?= $(KUBEWARDEN_HELM_REPO_NAME)
NAMESPACE ?= kubewarden

export CLUSTER_NAME ?= kubewarden-testing
CLUSTER_CONTEXT ?= k3d-$(CLUSTER_NAME)

O := $(shell helm repo add $(KUBEWARDEN_HELM_REPO_NAME) https://charts.kubewarden.io --force-update)
O := $(shell helm repo update $(KUBEWARDEN_HELM_REPO_NAME))

# Parse current and previous helm versions for upgrade test:
#   Current: last version from helm search kubewarden --devel
#   Old: version that is older than the current version and also not an "-rc"
KW_VERSIONS := $(shell helm search repo --fail-on-no-result $(KUBEWARDEN_HELM_REPO_NAME)/ --versions --devel -o json | tr -d \' \
	| jq -ec 'unique_by(.name) as $$c | { current:($$c | map({(.name): .version}) | add), old:map(select(.app_version != $$c[0].app_version and (.app_version | contains("rc") | not) )) | unique_by(.name)| map({(.name): .version}) | add}')

KUBEWARDEN_CONTROLLER_CHART_VERSION := $(shell echo '$(KW_VERSIONS)' | jq -er '.current["kubewarden/kubewarden-controller"]' || echo "*")
KUBEWARDEN_CRDS_CHART_VERSION       := $(shell echo '$(KW_VERSIONS)' | jq -er '.current["kubewarden/kubewarden-crds"]' || echo "*")
KUBEWARDEN_DEFAULTS_CHART_VERSION   := $(shell echo '$(KW_VERSIONS)' | jq -er '.current["kubewarden/kubewarden-defaults"]' || echo "*")

KUBEWARDEN_CONTROLLER_CHART_OLD_VERSION := $(shell echo '$(KW_VERSIONS)' | jq -er '.old["kubewarden/kubewarden-controller"]' || echo "*")
KUBEWARDEN_CRDS_CHART_OLD_VERSION       := $(shell echo '$(KW_VERSIONS)' | jq -er '.old["kubewarden/kubewarden-crds"]' || echo "*")
KUBEWARDEN_DEFAULTS_CHART_OLD_VERSION   := $(shell echo '$(KW_VERSIONS)' | jq -er '.old["kubewarden/kubewarden-defaults"]' || echo "*")

# CRD version to be tested
CRD_VERSION ?= $(shell helm show values $(KUBEWARDEN_CHARTS_LOCATION)/kubewarden-defaults --version '$(KUBEWARDEN_DEFAULTS_CHART_VERSION)' | yq ".crdVersion")
CRD_VERSION_SUFFIX ?= $(shell echo $(CRD_VERSION) | cut -d'/' -f2)
# directory with all the files used during the tests. This files are copied from
# $(ROOT_RESOURCES_DIR) and changed to used the CRDs version defined in $(CRD_VERSION)
RESOURCES_DIR ?= $(ROOT_RESOURCES_DIR)/resources_$(CRD_VERSION_SUFFIX)


# ==================================================================================================
# Aliases
kube = kubectl --context $(CLUSTER_CONTEXT) $(1)
helm = helm --kube-context $(CLUSTER_CONTEXT) $(1)
bats = RESOURCES_DIR=$(RESOURCES_DIR) \
	KUBEWARDEN_CRDS_CHART_OLD_VERSION=$(KUBEWARDEN_CRDS_CHART_OLD_VERSION) \
	KUBEWARDEN_DEFAULTS_CHART_OLD_VERSION=$(KUBEWARDEN_DEFAULTS_CHART_OLD_VERSION) \
	KUBEWARDEN_CONTROLLER_CHART_OLD_VERSION=$(KUBEWARDEN_CONTROLLER_CHART_OLD_VERSION) \
	KUBEWARDEN_CRDS_CHART_VERSION=$(KUBEWARDEN_CRDS_CHART_VERSION) \
	KUBEWARDEN_DEFAULTS_CHART_VERSION=$(KUBEWARDEN_DEFAULTS_CHART_VERSION) \
	KUBEWARDEN_CONTROLLER_CHART_VERSION=$(KUBEWARDEN_CONTROLLER_CHART_VERSION) \
	KUBEWARDEN_CHARTS_LOCATION=$(KUBEWARDEN_CHARTS_LOCATION) \
	KUBEWARDEN_HELM_REPO_NAME=$(KUBEWARDEN_HELM_REPO_NAME) \
	CLUSTER_CONTEXT=$(CLUSTER_CONTEXT) \
	NAMESPACE=$(NAMESPACE) \
		bats -T --print-output-on-failure $(1)

helm_in = $(helm) upgrade --install --wait --namespace $(NAMESPACE) --create-namespace

# ==================================================================================================
# Macros
define install-kubewarden =
	$(helm_in) kubewarden-crds $(KUBEWARDEN_CHARTS_LOCATION)/kubewarden-crds --version "$(KUBEWARDEN_CRDS_CHART_VERSION)"
	$(helm_in) kubewarden-controller $(KUBEWARDEN_CHARTS_LOCATION)/kubewarden-controller --version "$(KUBEWARDEN_CONTROLLER_CHART_VERSION)"
	$(helm_in) kubewarden-defaults $(KUBEWARDEN_CHARTS_LOCATION)/kubewarden-defaults --version "$(KUBEWARDEN_DEFAULTS_CHART_VERSION)"
	$(kube) wait --for=condition=Ready --namespace $(NAMESPACE) pods --all
endef

define generate-versioned-resources-dir =
	./scripts/generate_resources_dir.sh $(ROOT_RESOURCES_DIR) $(CRD_VERSION)
endef

# ==================================================================================================
# Targets

# Destructive tests that reinstall kubewarden
# Test is responsible for used kubewarden version
upgrade::
	$(generate-versioned-resources-dir)
	$(call bats, $(TESTS_DIR)/upgrade.bats)

# Generate target for every test file
TESTS := $(notdir $(wildcard tests/*.bats))
$(TESTS)::
	$(generate-versioned-resources-dir)
	$(call bats, $(TESTS_DIR)/$@)

# Target all non-destructive tests
.PHONY: tests
tests: $(filter-out upgrade.bats audit-scanner-installation.bats, $(TESTS))

.PHONY: cluster install reinstall clean

cluster:
	k3d cluster create $(CLUSTER_NAME) -s 1 -a 1 --wait -v /dev/mapper:/dev/mapper
	$(kube) wait --for=condition=Ready nodes --all

install:
	$(install-kubewarden)

clean:
	k3d cluster delete $(CLUSTER_NAME)

reinstall: clean cluster install
