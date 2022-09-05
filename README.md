# kubewarden-end-to-end-tests

This repository contains all the files necessary to run Kubewarden
end-to-end tests.

In the `tests` directory are stored the test written using the bats test framework.
The `reposources` directory contains all the files used during the tests execution,
like yaml files to deploy Kubernetes resources.

## Requirements

Tests are written using [bats](https://github.com/bats-core/bats-core).
The minimal required version is v1.5.0. So, it's necessary install it in your environment.
For that, you can check your OS packages repositories or follow the [official documentation](https://bats-core.readthedocs.io/en/stable/installation.html#installation).

Other required dependencies:

```bash
# k3d
curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash

# yq - python yq has different syntax then mikefarah binary
pip3 install yq

# Also kubectl, helm, docker, ...
```

## Setting up cluster & kubewarden

The Makefile has many targets to make easier to setup a test environment and
run the tasks:

```bash
make clean   # to remove previous k3d cluster
make cluster # to create new k3d cluster
make install # to install kubewarden (and cert-manager)

# or you can group 3 steps above into
make reinstall

# Optionally you can specify versions, see top of the Makefile for options
KUBEWARDEN_CONTROLLER_CHART_VERSION=0.3.2 make install
```


## Running the tests

Once you have a cluster with Kubewarden install, you can run the basic
e2e tests.

```bash
# All non-destructive tests have target auto-generated from filename
make monitor-mode-tests.bats reconfiguration-tests.bats

# There is also a target that groups all of them
make tests

# Upgrade tests is special since it reinstalls cluster
# It does not require cluster & kubewarden setup steps
make upgrade.bats

```


All the tests run on a given `kubectl` context. Thus, if you want to run the
tests on a cluster already in place, you need to define the context:

```console
CLUSTER_CONTEXT=k3d-mycluster make basic-end-to-end-test.bats
```

Also check the Kubewarden controller repository to see how run this test in a [Github
workflow](https://github.com/kubewarden/kubewarden-controller/blob/main/.github/workflows/e2e-tests.yml)
