/*
Copyright © 2022 - 2025 SUSE LLC

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

var _ = Describe("E2E - Build the airgap upgrade archive", Label("prepare-upgrade"), func() {
	It("Execute the script to build the archive", func() {

		// Could be useful for manual debugging!
		GinkgoWriter.Printf("Executed command: %s %s %s\n", airgapUpgradeScript, "build")
		out, err := exec.Command(airgapUpgradeScript, "build").CombinedOutput()
		Expect(err).To(Not(HaveOccurred()), string(out))
	})
})

var _ = Describe("E2E - Upgrade Kubewarden in airgap environment", Label("airgap-upgrade"), func() {
	It("Upgrade Kubewarden stack in airgap environment", func() {
		airgapRepo := os.Getenv("HOME") + "/airgap_upgrade"
		archiveFile := "haul_upgrade.tar.zst"
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

			// Send the hauler archive
			err := client.SendFile(airgapRepo+"/"+archiveFile, destFile, "0644")
			Expect(err).To(Not(HaveOccurred()))

			// Import the hauler store
			_, err = client.RunSSH(haulerBinary + " store load --filename " + optRancher + "/" + archiveFile)
			Expect(err).To(Not(HaveOccurred()))
		})

		By("Pushing updated artifacts with deploy script", func() {
			cmd := optRancher + "/k3s/upgrade-airgap deploy"

			// Could be useful for manual debugging!
			GinkgoWriter.Printf("Executed command: %s\n", cmd)
			out, err := client.RunSSH(cmd)
			Expect(err).To(Not(HaveOccurred()), string(out))
		})

		By("Upgrading Kubewarden crds", func() {
			// Set flags for Kubewarden-crds installation
			flags := []string{
				"upgrade", "kubewarden-crds", "oci://" + repoServer + "/hauler/kubewarden-crds",
				"--namespace", "kubewarden",
				"--create-namespace",
				"--plain-http",
				"--devel",
			}

			RunHelmCmdWithRetry(flags...)
		})

		By("Upgrading Kubewarden controller", func() {
			// Set flags for Kubewarden controller installation
			flags := []string{
				"upgrade", "kubewarden-controller", "oci://" + repoServer + "/hauler/kubewarden-controller",
				"--namespace", "kubewarden",
				"--plain-http",
				"--set", "global.cattle.systemDefaultRegistry=" + repoServer,
				"--set", "image.tag=" + kubewardenControllerVersion,
				"--set", "auditScanner.image.tag=" + auditScannerVersion,
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

		By("Upgrading Kubewarden defaults", func() {
			// Set flags for Kubewarden defaults installation
			flags := []string{
				"upgrade", "kubewarden-defaults", "oci://" + repoServer + "/hauler/kubewarden-defaults",
				"--namespace", "kubewarden",
				"--plain-http",
				"--set", "global.cattle.systemDefaultRegistry=" + repoServer,
				"--set", "policyServer.insecureSources[0]=" + rancherManager,
				"--set", "policyServer.insecureSources[1]=" + repoServer,
				"--set", "policyServer.image.tag=" + policyServerVersion,
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
