.DEFAULT_GOAL := all

MKFILE_DIR ?= $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
TESTS_DIR ?= $(MKFILE_DIR)tests
RESOURCES_DIR ?= $(MKFILE_DIR)resources

NAMESPACE ?= kubewarden
CLUSTER_CONTEXT ?= $(shell kubectl config current-context)

# ==================================================================================================
# Optional arguments for scripts

# cluster_k3d.sh:
#   MTLS=1
#   K3S=[1.30] - short|long version
#   CLUSTER_NAME=[k3d-default]

# helmer.sh:
#   VERSION=[next|prev|v1.17.0-rc2|local] (app version)
#   REPO_NAME=[kubewarden]
#   CHARTS_LOCATION=[./dirname|reponame]
#   LATEST=[1]
#   CRDS_ARGS, DEFAULTS_ARGS, CONTROLLER_ARGS

# ==================================================================================================
# Github boolean "false" is interpreted as a string (true) by bash
# Github falsy values (false, 0, -0, "", '', null) are coerced to false

# Boolean variables from github workflow
VARIABLES = MTLS LATEST UPGRADE

define is_falsy
$(filter false 0 -0 "" '' null,$($(1)))
endef

# Process each variable - if it has a falsy value, override it to be empty
$(foreach var,$(VARIABLES),$(if $(call is_falsy,$(var)),$(eval override $(var)=),))

# ==================================================================================================
# Targets

.PHONY: clean cluster install upgrade uninstall tests all

# Generate target for every test file
TESTFILES := $(notdir $(wildcard tests/*.bats))
$(TESTFILES):
	@RESOURCES_DIR=$(RESOURCES_DIR) \
	NAMESPACE=$(NAMESPACE) \
	CLUSTER_CONTEXT=$(CLUSTER_CONTEXT) \
	bats -T --print-output-on-failure $(TESTS_DIR)/$@

# Filter out audit-scanner-installation because it reinstalls kubewarden
FILTERED := $(filter-out audit-scanner-installation.bats, $(TESTFILES))
# Filter out mutual-tls if MTLS is not set
ifeq ($(MTLS),)
    FILTERED := $(filter-out mutual-tls.bats, $(TESTFILES))
endif
# Target all standard tests
tests: $(FILTERED)

cluster:
	./scripts/cluster_k3d.sh create

install: check
	./scripts/helmer.sh install

rancher:
	./scripts/rancher.sh install

upgrade:
	./scripts/helmer.sh upgrade

uninstall:
	./scripts/helmer.sh uninstall

clean:
	./scripts/cluster_k3d.sh delete

all: clean cluster install tests

check:
	@yq --version | grep mikefarah > /dev/null || { echo "yq is not the correct, needs mikefarah/yq!"; exit 1; }
	@jq --version > /dev/null || { echo "jq is not installed!"; exit 1; }
	@docker --version > /dev/null || { echo "docker is not installed!"; exit 1; }
	@k3d --version > /dev/null || { echo "k3d is not installed!"; exit 1; }
	@kubectl version --client > /dev/null || { echo "kubectl is not installed!"; exit 1; }
	@helm version > /dev/null || { echo "helm is not installed!"; exit 1; }
	@bats --version > /dev/null || { echo "bats is not installed!"; }
