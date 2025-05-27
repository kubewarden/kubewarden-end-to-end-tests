ROOT_DIR:=$(realpath $(PWD)/..)

# Define Ginkgo timeout for the tests
GINKGO_TIMEOUT?=3600

deps: 
	@go install -mod=mod github.com/onsi/ginkgo/v2/ginkgo
	@go install -mod=mod github.com/onsi/gomega
	@go mod tidy

# E2E tests
e2e-airgap-rancher: deps
	ginkgo --label-filter airgap-rancher -r -v ./e2e

e2e-prepare-archive: deps
	ginkgo --label-filter prepare-archive -r -v ./e2e
