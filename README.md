# kubewarden-end-to-end-tests

This repository contains all the files necessary to run Kubewarden
end-to-end tests.

In the `tests` directory are stored the test written using the bats test framework.
The `reposources` directory contains all the files used during the tests execution,
like yaml files to deploy Kubernetes resources.

## Running the tests

It's expected that you have a Kubernetes cluster with the Kubewarden stack
installed and accessible by default in your kubectl configuration.

It's possible run the end-to-end tests within a Github workflow or locally in
you machine. To run all the tests in your Kubernetes cluster:

```console
make runall
```

Check the Kubewarden controller repository to see how run this test in a [Github
workflow](https://github.com/kubewarden/kubewarden-controller/blob/main/.github/workflows/e2e-tests.yml)
