.DEFAULT_GOAL := check

MKFILE_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
TESTS_DIR := $(MKFILE_DIR)tests
RESOURCES_DIR := $(MKFILE_DIR)resources

NAMESPACE ?= $(shell helm status -n cattle-system rancher >/dev/null 2>&1 && echo "cattle-kubewarden-system" || echo "kubewarden")
CLUSTER_CONTEXT ?= $(shell kubectl config current-context)

# Should match version in https://docs.kubewarden.io/reference/dependency-matrix
OTEL_OPERATOR := $(or $(OTEL_OPERATOR),0.93.0)

export NAMESPACE OTEL_OPERATOR

# ==================================================================================================
# Optional arguments for scripts

# Requires bats >= v1.12.0
# KEEP=1 # Skip teardown on failure

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

# Generate target for every test file
TESTFILES := $(notdir $(wildcard $(TESTS_DIR)/*.bats))
# Filter out audit-scanner-installation because it reinstalls kubewarden
FILTERED := $(filter-out audit-scanner-installation.bats, $(TESTFILES))
# Filter out mutual-tls if MTLS is not set
ifeq ($(MTLS),)
    FILTERED := $(filter-out mutual-tls.bats, $(FILTERED))
endif
# Remove requested .bats targets from FILTERED to avoid duplicates
FILTERED := $(filter-out $(filter %.bats,$(MAKECMDGOALS)), $(FILTERED))

# If 'tests' appears in goals, substitute it with FILTERED tests
# Otherwise include any specified *.bats files in goals
BATS_SELECTED := $(strip $(foreach goal,$(MAKECMDGOALS),\
    $(if $(filter tests,$(goal)),$(FILTERED),\
    $(if $(filter %.bats,$(goal)),$(goal)))))
# If no goals specified, use filtered tests
BATS_SELECTED := $(or $(BATS_SELECTED),$(FILTERED))

# ==================================================================================================
# Use .run-bats to call bats only once per execution. Required to abort tests on failure

.PHONY: .run_bats tests $(TESTFILES)

.run_bats:
	@echo "Running BATS tests: $(BATS_SELECTED)"
	@RESOURCES_DIR="$(RESOURCES_DIR)" \
	CLUSTER_CONTEXT="$(CLUSTER_CONTEXT)" \
	bats -T --print-output-on-failure $(addprefix $(TESTS_DIR)/, $(BATS_SELECTED))

tests $(TESTFILES): .run_bats
	@:

# ==================================================================================================

.PHONY: clean cluster install rancher upgrade uninstall all check

cluster:
	./scripts/cluster_k3d.sh create

install:
	./scripts/helmer.sh install

rancher:
	./scripts/rancher.sh

upgrade:
	./scripts/helmer.sh upgrade

uninstall:
	./scripts/helmer.sh uninstall

clean:
	./scripts/cluster_k3d.sh delete

all: clean cluster install

check:
	@yq --version | grep mikefarah > /dev/null || { echo "yq is not the correct, needs mikefarah/yq!"; exit 1; }
	@jq --version > /dev/null || { echo "jq is not installed!"; exit 1; }
	@docker --version > /dev/null || { echo "docker is not installed!"; exit 1; }
	@k3d --version > /dev/null || { echo "k3d is not installed!"; exit 1; }
	@kubectl version --client > /dev/null || { echo "kubectl is not installed!"; exit 1; }
	@helm version > /dev/null || { echo "helm is not installed!"; exit 1; }
	@bats --version > /dev/null || { echo "bats is not installed!"; }
	@echo "Dependency check passed."
