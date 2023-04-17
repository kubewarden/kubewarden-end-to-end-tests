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
		--set policyServer.sourceAuthorities=null
}

# https://www.baeldung.com/openssl-self-signed-cert
@test "[Private Registry] Generate certificates" {
	certdir="$BATS_RUN_TMPDIR/certs/"
	mkdir $certdir && cd $certdir

	# Create CA
	openssl req -nodes -batch -x509 -sha256 -days 365 -newkey rsa:2048 -keyout rootCA.key -out rootCA.crt
	# Create CSR
	openssl req -nodes -batch -newkey rsa:2048 -keyout domain.key -out domain.csr \
		-addext "subjectAltName = DNS:$FQDN"
	# Create CRT
	openssl x509 -req -CA rootCA.crt -CAkey rootCA.key -in domain.csr -out domain.crt -days 365 -CAcreateserial \
		-extfile <(echo "subjectAltName=DNS:$FQDN")
	# Print CRT
	openssl x509 -text -noout -in domain.crt

	cd -
}

# https://medium.com/geekculture/deploying-docker-registry-on-kubernetes-3319622b8f32
@test "[Private Registry] Generate AUTH and start registry" {
	certdir="$BATS_RUN_TMPDIR/certs/"

	# Create configmap from htpasswd
	# docker run --entrypoint htpasswd httpd:2 -Bbn testuser testpassword
	kubectl create cm registry-auth \
		--from-literal htpasswd='testuser:$2y$05$bkWZdztgNvW.akipcacKb.nueDup8NGbcTtvqDKG.3keAgUDufapm'

	# Create secret with certificates
	kubectl create secret tls registry-cert \
		--cert=$certdir/domain.crt --key=$certdir/domain.key

	kubectl apply -f $RESOURCES_DIR/private-registry-deploy.yaml
	wait_rollout 'deploy/registry'
}

@test "[Private Registry] Pull & Push policy to registry" {
	jq -n --arg r $REGISTRY \
		'{"auths": {($r): {"auth": "dGVzdHVzZXI6dGVzdHBhc3N3b3Jk"}}}' > "$BATS_RUN_TMPDIR/config.json"
	jq -n --arg r $REGISTRY --arg crt "$BATS_RUN_TMPDIR/certs/rootCA.crt" \
		'{"source_authorities":{($r):[{"type":"Path","path":$crt}]}}' > "$BATS_RUN_TMPDIR/sources.json"

	kwctl pull $PUB_POLICY
	kwctl push $PUB_POLICY $PRIV_POLICY \
		--docker-config-json-path $BATS_RUN_TMPDIR \
		--sources-path "$BATS_RUN_TMPDIR/sources.json"
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
		--set policyServer.sourceAuthorities[0].uri="$REGISTRY" \
		--set-file policyServer.sourceAuthorities[0].certs[0]="$BATS_RUN_TMPDIR/certs/rootCA.crt"

	helm get values -n kubewarden kubewarden-defaults
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
