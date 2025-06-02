[![Kubewarden Infra Repository](https://github.com/kubewarden/community/blob/main/badges/kubewarden-infra.svg)](https://github.com/kubewarden/community/blob/main/REPOSITORIES.md#infra-scope)
[![Stable](https://img.shields.io/badge/status-stable-brightgreen?style=for-the-badge)](https://github.com/kubewarden/community/blob/main/REPOSITORIES.md#stable)

## [Charts test matrix](https://github.com/kubewarden/helm-charts/blob/main/.github/workflows/e2e-tests.yml)

| Trigger            	| Charts          	| K3S 	| Notes               	| Status 	|
|--------------------	|-----------------	|-----	|----------------------	| :--------: |
| nightly (schedule) 	| latest tag      	| k3d 	|                      	| [![E2E](https://github.com/kubewarden/helm-charts/actions/workflows/e2e-tests.yml/badge.svg?event=schedule)](https://github.com/kubewarden/helm-charts/actions/workflows/e2e-tests.yml?query=event%3Aschedule) |
|                    	| source (main)   	| k3d 	| :latest images       	|  |
| airgap (every Friday)| latest tag       | k3s   |                       | [![Airgap E2E Tests](https://github.com/kubewarden/helm-charts/actions/workflows/e2e-airgap.yml/badge.svg?event=schedule)](https://github.com/kubewarden/helm-charts/actions/workflows/e2e-airgap.yml?query=event%3Aschedule) |
| release (tag)      	| release tag     	| k3d 	|                      	| [![E2E](https://github.com/kubewarden/helm-charts/actions/workflows/e2e-tests.yml/badge.svg?event=workflow_run)](https://github.com/kubewarden/helm-charts/actions/workflows/e2e-tests.yml?query=event%3Aworkflow_run) |
|                    	| previous stable 	| k3d 	| upgrade to released  	|  |
|                    	| release tag     	| old 	| oldest supported k8s 	|  |
| pull request       	| source (pr)     	| k3d 	|                      	|  |
| manual             	| any             	| any 	| any                  	|  |

# kubewarden-end-to-end-tests

This repository contains all the files necessary to run Kubewarden
end-to-end tests.

In the `tests` directory are stored the test written using the bats test framework.
The `reposources` directory contains all the files used during the tests execution,
like yaml files to deploy Kubernetes resources.

## Requirements

> **Note:** this repository makes use of git submodules. Ensure you run the following
> command:
>
> ```console
> git submodule update --init
> ```

Tests are written using [bats](https://github.com/bats-core/bats-core).
The minimal required version is v1.7.0. So, it's necessary install it in your environment.
For that, you can check your OS packages repositories or follow the [official documentation](https://bats-core.readthedocs.io/en/stable/installation.html#installation).

Other required dependencies:

```bash
# k3d
curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash

# yq - python yq has different syntax then mikefarah binary
Use mikefarah binary, github-runners and zypper default to it

# Also kubectl, helm, docker, ...you can run:
make check
```

## Setting up cluster & kubewarden

The Makefile has many targets to make easier to setup a test environment and
run the tasks:

```bash

# Install :latest images and custom args
make
  cluster K3S=1.30 \
  install LATEST=1 DEFAULTS_ARGS="--set recommendedPolicies.enabled=True" CONTROLLER_ARGS="-f custom.yaml"

# Install from local directory
ln -s ../helm-charts/charts
make cluster install CHARTS_LOCATION=./charts

# Install previous stable version upgrade to local chart
make cluster install VERSION=prev
make upgrade CHARTS_LOCATION=./charts

# Delete cluster
make clean
```

## Running the tests

Once you have a cluster with Kubewarden install, you can run tests.

```bash
# All testfiles have target auto-generated from filename
make monitor-mode-tests.bats reconfiguration-tests.bats

# Run all tests
make tests
```

All the tests run on a given `kubectl` context. Thus, if you want to run the
tests on a cluster already in place, you need to define the context:

```console
CLUSTER_CONTEXT=k3d-mycluster make basic-end-to-end-test.bats
```

Also check the helm-charts repository to see how run this test in a [Github
workflow](https://github.com/kubewarden/helm-charts/blob/main/.github/workflows/e2e-tests.yml)

## Updating policies

```
~ cd kwctl/e2e-tests/test-data/sigstore
~ COSIGN_PASSWORD=kubewarden cosign sign --key cosign1.key -a env=prod -a stable=true ghcr.io/kubewarden/tests/pod-privileged:v0.2.1
~ COSIGN_PASSWORD=kubewarden cosign sign --key cosign2.key -a env=prod ghcr.io/kubewarden/tests/pod-privileged:v0.2.1
```
