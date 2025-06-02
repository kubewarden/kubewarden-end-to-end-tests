# Kubewarden airgap test

This test is used to validate the installation of Kubewarden and the deployment of the recommended policies in an air-gapped environment.

The first step is to use a GitHub runner to create a virtual machine in GCP and attach it as a self-hosted runner in the repository.

Next, we use this new runner to create an isolated libvirt network as well as a virtual machine that will therefore have no internet access.

On this runner, we retrieve the artifacts necessary for the installation of Kubewarden, such as the Helm charts, container images, policy images and K3S.
Then, all these artifacts are consumed by [Hauler](https://docs.hauler.dev/docs/intro), and a Hauler store archive is created and sent to the isolated virtual machine.

Hauler is also installed on the virtual machine. We use the Hauler archive to create a new Hauler store within the virtual machine.
Next, we start by installing K3S on the virtual machine and deploying an internal registry to host our Hauler artifacts.

Finally, we install the Kubewarden components from our internal registry and ensure that the recommended policies are in the active status.

## How to troubleshoot the airgap test

The test is scheduled to run every Friday, but you can also trigger it manually using the workflow dispatch feature.

Additionally, if the previous test failed and you want to investigate, you can uncheck the "Destroy the auto-generated self-hosted runner" option. This way, the runner won't be deleted at the end of the test.

You can then go to the GCP interface and SSH into the runner to inspect whatever you need. You can even connect to the isolated VM via the libvirt network using:

`ssh root@192.168.122.102`

Once you're done, you can manually delete the runner from the GCP interface. In any case, the runner is automatically destroyed after 10 hours.
