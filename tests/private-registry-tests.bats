#!/usr/bin/env bats
# https://github.com/kubewarden/kubewarden-controller/pull/421

setup() {
	load common.bash
	wait_pods

	FQDN=$(k3d node get k3d-$CLUSTER_NAME-server-0 -o json | jq -r 'first.IP.IP').nip.io
	REGISTRY=$FQDN:30707
	PUB_POLICY=registry://ghcr.io/kubewarden/tests/pod-privileged:v0.2.1
	PRIV_POLICY=registry://$REGISTRY/kubewarden/tests/pod-privileged:v0.2.1
}

teardown_file() {
	load common.bash
	kubectl delete -f $RESOURCES_DIR/private-registry-deploy.yaml ||:
	kubectl delete cm registry-auth ||:
	kubectl delete secret registry-cert ||:

	kubectl --namespace kubewarden delete secret secret-registry-docker ||:
	kubectl delete clusteradmissionpolicies private-pod-privileged ||:
	helm_in kubewarden-defaults --reuse-values \
		--set policyServer.imagePullSecret=null \
		--set policyServer.insecureSources=null
}

# https://medium.com/geekculture/deploying-docker-registry-on-kubernetes-3319622b8f32
@test "[Private Registry] Generate AUTH, CERT and start registry" {
	tmpdir="$BATS_RUN_TMPDIR/certs/"

	# Create configmap from htpasswd
	# docker run --entrypoint htpasswd httpd:2 -Bbn testuser testpassword
	kubectl create cm registry-auth \
		--from-literal htpasswd='testuser:$2y$05$bkWZdztgNvW.akipcacKb.nueDup8NGbcTtvqDKG.3keAgUDufapm'

	# Create secret with certificates
	mkdir -p $tmpdir
	openssl req -batch \
		-newkey rsa:4096 -nodes -sha256 -keyout $tmpdir/domain.key \
		-addext "subjectAltName = DNS:$FQDN" \
		-x509 -days 365 -out $tmpdir/domain.crt

	kubectl create secret tls registry-cert \
		--cert=$tmpdir/domain.crt --key=$tmpdir/domain.key

	kubectl apply -f $RESOURCES_DIR/private-registry-deploy.yaml
	wait_rollout 'deploy/registry'
}

@test "[Private Registry] Pull & Push policy to registry" {
	config="$BATS_RUN_TMPDIR/config.json"
	jq -n --arg r $REGISTRY '{"auths": {($r): {"auth": "dGVzdHVzZXI6dGVzdHBhc3N3b3Jk"}}}' > $config

	kwctl pull $PUB_POLICY
	kwctl push $PUB_POLICY $PRIV_POLICY \
		--docker-config-json-path $BATS_RUN_TMPDIR \
		--sources-path <(echo "insecure_sources: [$REGISTRY]")
}

# https://docs.kubewarden.io/operator-manual/policy-servers/private-registry
@test "[Private Registry] Set up policy server access to registry" {
	# Create secret to access registry
	kubectl --namespace kubewarden create secret docker-registry secret-registry-docker \
	  --docker-username=testuser \
	  --docker-password=testpassword \
	  --docker-server=$REGISTRY

	# Edit default policy server config
	helm_in kubewarden-defaults --reuse-values \
		--set policyServer.imagePullSecret=secret-registry-docker \
		--set policyServer.insecureSources[0]=$REGISTRY
}

@test "[Private Registry] Check I can deploy policy from auth registry" {
	policy="$BATS_RUN_TMPDIR/private-policy.yaml"

	kwctl scaffold manifest --type=ClusterAdmissionPolicy $PUB_POLICY |\
		yq -y '.metadata.name = "private-pod-privileged"' |\
		yq -y --arg r $PRIV_POLICY '.spec.module = $r' > $policy

	# Make sure we use private registry
	grep -F "module: registry://$REGISTRY" $policy
	apply_cluster_admission_policy $policy
	kubectl get clusteradmissionpolicies private-pod-privileged -o json | jq -e '.status.policyStatus == "active"'
}
