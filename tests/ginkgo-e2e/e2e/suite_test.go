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
	"strings"
	"testing"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/rancher-sandbox/ele-testhelpers/kubectl"
	"github.com/rancher-sandbox/ele-testhelpers/rancher"
	"github.com/rancher-sandbox/ele-testhelpers/tools"
)

const (
	airgapBuildScript   = "../scripts/build-airgap"
	backupYaml          = "../assets/backup.yaml"
	ciTokenYaml         = "../assets/local-kubeconfig-token-skel.yaml"
	installConfigYaml   = "../../install-config.yaml"
	localKubeconfigYaml = "../assets/local-kubeconfig-skel.yaml"
	restoreYaml         = "../assets/restore.yaml"
	upgradeSkelYaml     = "../assets/upgrade_skel.yaml"
	userName            = "root"
	userPassword        = "r0s@pwd1"
	vmNameRoot          = "node"
)

var (
	auditScannerVersion         string
	backupRestoreVersion        string
	clusterNS                   string
	kubewardenControllerVersion string
	policyServerVersion         string
	k3sVersion                  string
	netDefaultFileName          string
	rancherHostname             string
)

func CheckBackupRestore(v string) {
	Eventually(func() string {
		out, _ := kubectl.RunWithoutErr("logs", "-l app.kubernetes.io/name=rancher-backup",
			"--tail=-1", "--since=5m",
			"--namespace", "cattle-resources-system")
		return out
	}, tools.SetTimeout(5*time.Minute), 10*time.Second).Should(ContainSubstring(v))
}

/*
Get configured backup directory
  - @returns Configured backup directory
*/
func GetBackupDir() string {
	claimName, err := kubectl.RunWithoutErr("get", "pod", "-l", "app.kubernetes.io/name=rancher-backup",
		"--namespace", "cattle-resources-system",
		"-o", "jsonpath={.items[*].spec.volumes[?(@.name==\"pv-storage\")].persistentVolumeClaim.claimName}")
	Expect(err).To(Not(HaveOccurred()))

	out, err := kubectl.RunWithoutErr("get", "pv",
		"--namespace", "cattle-resources-system",
		"-o", "jsonpath={.items[?(@.spec.claimRef.name==\""+claimName+"\")].spec.local.path}")
	Expect(err).To(Not(HaveOccurred()))

	return out
}

/*
Install rancher-backup operator
  - @param k kubectl structure
  - @returns Nothing, the function will fail through Ginkgo in case of issue
*/
func InstallBackupOperator(k *kubectl.Kubectl) {
	// Default chart
	chartRepo := "rancher-chart"

	// Set specific operator version if defined
	if backupRestoreVersion != "" {
		chartRepo = "https://github.com/rancher/backup-restore-operator/releases/download/" + backupRestoreVersion
	} else {
		RunHelmCmdWithRetry("repo", "add", chartRepo, "https://charts.rancher.io")
		RunHelmCmdWithRetry("repo", "update")
	}

	for _, chart := range []string{"rancher-backup-crd", "rancher-backup"} {
		// Set the filename in chart if a custom version is defined
		chartName := chart
		if backupRestoreVersion != "" {
			chartName = chart + "-" + strings.Trim(backupRestoreVersion, "v") + ".tgz"
		}

		// Global installation flags
		flags := []string{
			"upgrade", "--install", chart, chartRepo + "/" + chartName,
			"--namespace", "cattle-resources-system",
			"--create-namespace",
			"--wait", "--wait-for-jobs",
		}

		// Add specific options for the rancher-backup chart
		if chart == "rancher-backup" {
			flags = append(flags,
				"--set", "persistence.enabled=true",
				"--set", "persistence.storageClass=local-path",
			)
		}

		RunHelmCmdWithRetry(flags...)

		Eventually(func() error {
			return rancher.CheckPod(k, [][]string{{"cattle-resources-system", "app.kubernetes.io/name=rancher-backup"}})
		}, tools.SetTimeout(4*time.Minute), 30*time.Second).Should(Not(HaveOccurred()))
	}
}

/*
Install K3s
  - @returns Nothing, the function will fail through Ginkgo in case of issue
*/
func InstallK3s() {
	// Get K3s installation script
	fileName := "k3s-install.sh"
	Eventually(func() error {
		return tools.GetFileFromURL("https://get.k3s.io", fileName, true)
	}, tools.SetTimeout(2*time.Minute), 10*time.Second).ShouldNot(HaveOccurred())

	// Set command and arguments
	installCmd := exec.Command("sh", fileName)
	installCmd.Env = append(os.Environ(), "INSTALL_K3S_EXEC=--disable metrics-server")

	// Retry in case of (sporadic) failure...
	count := 1
	Eventually(func() error {
		// Execute K3s installation
		out, err := installCmd.CombinedOutput()
		GinkgoWriter.Printf("K3s installation loop %d:\n%s\n", count, out)
		count++
		return err
	}, tools.SetTimeout(2*time.Minute), 5*time.Second).Should(Not(HaveOccurred()))
}

/*
Install Kubewarden
  - @param k kubectl structure
  - @returns Nothing, the function will fail through Ginkgo in case of issue
*/
func InstallKubewarden(k *kubectl.Kubectl) {
	// Install Kubewarden CRDs
	RunHelmCmdWithRetry("repo", "add", "kubewarden", "https://charts.kubewarden.io")
	RunHelmCmdWithRetry("repo", "update")

	// Default chart
	chartRepo := "kubewarden"

	for _, chart := range []string{"kubewarden-crds", "kubewarden-controller", "kubewarden-defaults"} {
		// Set the filename in chart if a custom version is defined
		chartName := chart

		// Global installation flags
		flags := []string{
			"upgrade", "--install", chart, chartRepo + "/" + chartName,
			"--namespace", "kubewarden",
			"--create-namespace",
			"--wait", "--wait-for-jobs",
		}

		// Add specific options for the rancher-backup chart
		if chart == "kubewarden-controller" {
			flags = append(flags,
				"--set", "auditScanner.policyReporter=true",
				"--set", "auditScanner.cronJob.schedule=*/2 * * * *",
			)
		}

		if chart == "kubewarden-defaults" {
			flags = append(flags,
				"--set", "recommendedPolicies.enabled=true",
			)
		}
		RunHelmCmdWithRetry(flags...)
	}

	// Wait for all pods to be started
	checkList := [][]string{
		{"kubewarden", "app.kubernetes.io/name=kubewarden-controller"},
		{"kubewarden", "app.kubernetes.io/name=policy-server"},
	}
	err := rancher.CheckPod(k, checkList)
	Expect(err).To(Not(HaveOccurred()))
}

/*
Start K3s
  - @returns Nothing, the function will fail through Ginkgo in case of issue
*/
func StartK3s() {
	err := exec.Command("sudo", "systemctl", "start", "k3s").Run()
	Expect(err).To(Not(HaveOccurred()))
}

/*
Execute RunHelmBinaryWithCustomErr within a loop with timeout
  - @param s options to pass to RunHelmBinaryWithCustomErr command
  - @returns Nothing, the function will fail through Ginkgo in case of issue
*/
func RunHelmCmdWithRetry(s ...string) {
	Eventually(func() error {
		return kubectl.RunHelmBinaryWithCustomErr(s...)
	}, tools.SetTimeout(2*time.Minute), 20*time.Second).Should(Not(HaveOccurred()))
}

/*
Check SSH connection
  - @param cl Client (node) informations
  - @returns Nothing, the function will fail through Ginkgo in case of issue
*/
func CheckSSH(cl *tools.Client) {
	Eventually(func() string {
		out, _ := cl.RunSSH("echo SSH_OK")
		return strings.Trim(out, "\n")
	}, tools.SetTimeout(10*time.Minute), 5*time.Second).Should(Equal("SSH_OK"))
}

func FailWithReport(message string, callerSkip ...int) {
	// Ensures the correct line numbers are reported
	Fail(message, callerSkip[0]+1)
}

/*
Wait for K3s to start
  - @param k kubectl structure
  - @returns Nothing, the function will fail through Ginkgo in case of issue
*/
func WaitForK3s(k *kubectl.Kubectl) {
	// Check Pod(s)
	checkList := [][]string{
		{"kube-system", "app=local-path-provisioner"},
		{"kube-system", "k8s-app=kube-dns"},
		{"kube-system", "app.kubernetes.io/name=traefik"},
		{"kube-system", "svccontroller.k3s.cattle.io/svcname=traefik"},
	}
	Eventually(func() error {
		return rancher.CheckPod(k, checkList)
	}, tools.SetTimeout(4*time.Minute), 30*time.Second).Should(Not(HaveOccurred()))

	// Check DaemonSet(s)
	checkList = [][]string{
		{"kube-system", "svccontroller.k3s.cattle.io/svcname=traefik"},
	}
	Eventually(func() error {
		return rancher.CheckDaemonSet(k, checkList)
	}, tools.SetTimeout(4*time.Minute), 30*time.Second).Should(Not(HaveOccurred()))
}

func TestE2E(t *testing.T) {
	RegisterFailHandler(FailWithReport)
	RunSpecs(t, "Elemental End-To-End Test Suite")
}

var _ = BeforeSuite(func() {
	auditScannerVersion = os.Getenv("AUDIT_SCANNER_VERSION")
	backupRestoreVersion = os.Getenv("BACKUP_RESTORE_VERSION")
	kubewardenControllerVersion = os.Getenv("KUBEWARDEN_CONTROLLER_VERSION")
	policyServerVersion = os.Getenv("POLICY_SERVER_VERSION")
	k3sVersion = os.Getenv("K3S_VERSION")
	netDefaultFileName = "../assets/net-default-airgap.xml"
	rancherHostname = os.Getenv("PUBLIC_FQDN")
})
