# kubewarden-end-to-end-tests

This repository contains all the files necessary to run Kubewarden
end-to-end tests.

In the `tests` directory are stored the test written using the bats test framework.
The `reposources` directory contains all the files used during the tests execution,
like yaml files to deploy Kubernetes resources.

## Requirements

Most of the tests are written using [bats](https://github.com/bats-core/bats-core).
The version used is v1.5.0. So, it's necessary install it in your environment.
For that, you can check your OS packages repositories or follow the [official documentation](https://bats-core.readthedocs.io/en/stable/installation.html#installation).

Other dependencies can be install with the following command:

```console
make setup
```

## Running the tests

The Makefile has many targets to make easier to setup a test environment and
running the tasks. You can start a K3D cluster to run your tests:

```console
make create-k8s-cluster
```

Install a given Kubewarden version:

```
make install-kubewarden
```

If you want to install a chart version different from the default one, you can
overwrite the `KUBEWARDEN_CONTROLLER_CHART_VERSION` variable:

```console
KUBEWARDEN_CONTROLLER_CHART_VERSION=0.3.2 make install-kubewarden
```

Once you have a cluster with Kubewarden install, you can run all tests:

```console
make runall
```

All the tests run on a given `kubectl` context. Thus, if you want to run the
tests on a cluster already in place, you need to define the context:

```console
CLUSTER_CONTEXT=k3d-mycluster make runall
```

Also check the Kubewarden controller repository to see how run this test in a [Github
workflow](https://github.com/kubewarden/kubewarden-controller/blob/main/.github/workflows/e2e-tests.yml)
