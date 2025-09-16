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

e2e-airgap-upgrade: deps
	ginkgo --label-filter airgap-upgrade -r -v ./e2e

e2e-full-backup-restore: deps
	ginkgo --label-filter test-full-backup-restore -r -v ./e2e

e2e-install-backup-restore: deps
	ginkgo --label-filter install-backup-restore -r -v ./e2e

e2e-install-kubewarden: deps
	ginkgo --label-filter install-kubewarden -r -v ./e2e

e2e-install-k3s: deps
	ginkgo --label-filter install-k3s -r -v ./e2e

e2e-prepare-archive: deps
	ginkgo --label-filter prepare-archive -r -v ./e2e

e2e-prepare-upgrade: deps
	ginkgo --label-filter prepare-upgrade -r -v ./e2e
