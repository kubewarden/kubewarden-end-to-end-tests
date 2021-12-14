mkfile_path := $(abspath $(lastword $(MAKEFILE_LIST)))
mkfile_dir := $(dir $(mkfile_path))
TESTS_DIR ?= "$(mkfile_dir)tests"
RESOURCES_DIR ?= "$(mkfile_dir)resources"

.PHONY: runall
runall:
	RESOURCES_DIR=$(RESOURCES_DIR) bats \
		--verbose-run \
		--show-output-of-passing-tests \
		--recursive \
		$(TESTS_DIR)
