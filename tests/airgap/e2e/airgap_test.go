/*
Copyright © 2022 - 2023 SUSE LLC

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at
    http://www.apache.org/licenses/LICENSE-2.0
Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package e2e_test

import (
	"os"
	"os/exec"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/rancher-sandbox/ele-testhelpers/kubectl"
	"github.com/rancher-sandbox/ele-testhelpers/rancher"
	"github.com/rancher-sandbox/ele-testhelpers/tools"
)

var _ = Describe("E2E - Build the airgap archive", Label("prepare-archive"), func() {
	It("Execute the script to build the archive", func() {

		// Could be useful for manual debugging!
		GinkgoWriter.Printf("Executed command: %s %s %s %s %s\n", airgapBuildScript, k3sVersion)
		out, err := exec.Command(airgapBuildScript, k3sVersion).CombinedOutput()
		Expect(err).To(Not(HaveOccurred()), string(out))
	})
})

var _ = Describe("E2E - Deploy K3S/Rancher in airgap environment", Label("airgap-rancher"), func() {
	It("Create the rancher-manager machine", func() {
		By("Updating the default network configuration", func() {
			// Don't check return code, as the default network could be already removed
			for _, c := range []string{"net-destroy", "net-undefine"} {
				_ = exec.Command("sudo", "virsh", c, "default").Run()
			}

			// Wait a bit between virsh commands
			time.Sleep(30 * time.Second)
			err := exec.Command("sudo", "virsh", "net-create", netDefaultFileName).Run()
			Expect(err).To(Not(HaveOccurred()))
		})

		By("Creating the Rancher Manager VM", func() {
			err := exec.Command("sudo", "virt-install",
				"--name", "rancher-manager",
				"--memory", "16384",
				"--vcpus", "4",
				"--disk", "path="+os.Getenv("HOME")+"/rancher-image.qcow2,bus=sata",
				"--import",
				"--os-variant", "opensuse-unknown",
				"--network=default,mac=52:54:00:00:00:10",
				"--noautoconsole").Run()
			Expect(err).To(Not(HaveOccurred()))
		})
	})

	It("Install K3S/Rancher in the rancher-manager machine", func() {
		airgapRepo := os.Getenv("HOME") + "/airgap_rancher"
		archiveFile := "haul.tar.zst"
		haulerBinary := "/usr/local/bin/hauler"
		optRancher := "/opt/rancher"
		password := "root"
		rancherManager := "rancher-manager.test"
		repoServer := rancherManager + ":5000"
		userName := "root"

		// For ssh access
		client := &tools.Client{
			Host:     "192.168.122.102:22",
			Username: userName,
			Password: password,
		}

		// Create kubectl context
		// Default timeout is too small, so New() cannot be used
		k := &kubectl.Kubectl{
			Namespace:    "",
			PollTimeout:  tools.SetTimeout(300 * time.Second),
			PollInterval: 500 * time.Millisecond,
		}

		By("Sending the archive file into the rancher server", func() {
			// Destination archive file
			destFile := optRancher + "/" + archiveFile

			// Make sure SSH is available
			CheckSSH(client)

			// Create the destination repository
			_, err := client.RunSSH("mkdir -p " + optRancher)
			Expect(err).To(Not(HaveOccurred()))

			// Send the hauler archive
			err = client.SendFile(airgapRepo+"/"+archiveFile, destFile, "0644")
			Expect(err).To(Not(HaveOccurred()))

			// Send the hauler binary
			err = client.SendFile(haulerBinary, haulerBinary, "0755")
			Expect(err).To(Not(HaveOccurred()))

			// Import the hauler store
			_, err = client.RunSSH(haulerBinary + " store load --filename " + optRancher + "/" + archiveFile)
			Expect(err).To(Not(HaveOccurred()))
		})

		By("Deploying airgap infrastructure by executing the deploy script", func() {
			_, err := client.RunSSH("sudo sh -c \"" + haulerBinary + " store extract hauler/k3s -o " + optRancher + "\"")
			Expect(err).To(Not(HaveOccurred()))

			cmd := optRancher + "/k3s/deploy-airgap " + k3sVersion

			// Could be useful for manual debugging!
			GinkgoWriter.Printf("Executed command: %s\n", cmd)
			out, err := client.RunSSH(cmd)
			Expect(err).To(Not(HaveOccurred()), string(out))
		})

		By("Getting the kubeconfig file of the airgap cluster", func() {
			// Define local Kubeconfig file
			localKubeconfig := os.Getenv("HOME") + "/.kube/config"

			err := os.Mkdir(os.Getenv("HOME")+"/.kube", 0755)
			Expect(err).To(Not(HaveOccurred()))

			err = client.GetFile(localKubeconfig, "/etc/rancher/k3s/k3s.yaml", 0644)
			Expect(err).To(Not(HaveOccurred()))

			// NOTE: not sure that this is need because we have the config file in ~/.kube/
			err = os.Setenv("KUBECONFIG", localKubeconfig)
			Expect(err).To(Not(HaveOccurred()))

			// Replace localhost with the IP of the VM
			err = tools.Sed("127.0.0.1", "192.168.122.102", localKubeconfig)
			Expect(err).To(Not(HaveOccurred()))
		})

		By("Installing kubectl", func() {
			// TODO: Variable for kubectl version
			err := exec.Command("curl", "-sLO", "https://dl.k8s.io/release/v1.28.2/bin/linux/amd64/kubectl").Run()
			Expect(err).To(Not(HaveOccurred()))
			err = exec.Command("chmod", "+x", "kubectl").Run()
			Expect(err).To(Not(HaveOccurred()))
			err = exec.Command("sudo", "mv", "kubectl", "/usr/local/bin/").Run()
			Expect(err).To(Not(HaveOccurred()))
		})

		By("Installing Kubewarden crds", func() {
			// Set flags for Kubewarden-crds installation
			flags := []string{
				"upgrade", "--install", "kubewarden-crds", "oci://" + repoServer + "/hauler/kubewarden-crds",
				"--namespace", "kubewarden",
				"--create-namespace",
				"--plain-http",
				"--devel",
			}

			RunHelmCmdWithRetry(flags...)
		})

		By("Installing Kubewarden controller", func() {
			// Set flags for Kubewarden controller installation
			flags := []string{
				"upgrade", "--install", "kubewarden-controller", "oci://" + repoServer + "/hauler/kubewarden-controller",
				"--namespace", "kubewarden",
				"--plain-http",
				"--set", "global.cattle.systemDefaultRegistry=" + repoServer,
				"--set", "image.tag=latest",
				"--set", "auditScanner.image.tag=latest",
				"--wait", "--wait-for-jobs",
				"--devel",
			}

			RunHelmCmdWithRetry(flags...)

			// Wait for all pods to be started
			checkList := [][]string{
				{"kubewarden", "app.kubernetes.io/name=kubewarden-controller"},
			}
			err := rancher.CheckPod(k, checkList)
			Expect(err).To(Not(HaveOccurred()))
		})

		By("Installing Kubewarden defaults", func() {
			// Set flags for Kubewarden defaults installation
			flags := []string{
				"upgrade", "--install", "kubewarden-defaults", "oci://" + repoServer + "/hauler/kubewarden-defaults",
				"--namespace", "kubewarden",
				"--plain-http",
				"--set", "global.cattle.systemDefaultRegistry=" + repoServer,
				"--set", "policyServer.insecureSources[0]=" + rancherManager,
				"--set", "policyServer.insecureSources[1]=" + repoServer,
				"--set", "policyServer.image.tag=latest",
				"--set", "recommendedPolicies.enabled=true",
				"--set", "recommendedPolicies.defaultPoliciesRegistry=" + repoServer,
				"--wait", "--wait-for-jobs",
				"--devel",
			}
			RunHelmCmdWithRetry(flags...)

			// Wait for pod to be started
			err := rancher.CheckPod(k, [][]string{{"kubewarden", "app.kubernetes.io/name=policy-server"}})
			Expect(err).To(Not(HaveOccurred()))

		})
		// TODO: check all policies
		By("Checking that one policy is in active state", func() {
			Eventually(func() string {
				out, _ := kubectl.RunWithoutErr("get", "cap", "do-not-run-as-root",
					"-o", "jsonpath={.status.policyStatus}")
				return out
			}, tools.SetTimeout(5*time.Minute), 10*time.Second).Should(ContainSubstring("active"))
		})
	})
})
