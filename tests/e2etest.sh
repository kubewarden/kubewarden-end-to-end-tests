step 'base tests'

## Create pod-privileged policy to block CREATE & UPDATE of privileged pods
info 'Apply pod-privileged policy that blocks CREATE & UPDATE'
apply_policy $DATADIR/policy-pod-privileged.yaml
# Launch unprivileged pod
kubectl run nginx-unprivileged --image=nginx:alpine
# Launch privileged pod (should fail)
kubefail_privileged run pod-privileged --image=k8s.gcr.io/pause --privileged


## Update pod-privileged policy to block only UPDATE of privileged pods
info 'Patch policy to block only UPDATE operation'
yq '.spec.rules[0].operations = ["UPDATE"]' $DATADIR/policy-pod-privileged.yaml | kubectl apply -f -
# I can create privileged pods now
kubectl run nginx-privileged --image=nginx:alpine --privileged
# I can not update privileged pods
kubefail_privileged label pod nginx-privileged x=y


info 'Delete ClusterAdmissionPolicy'
kubectl delete -f $DATADIR/policy-pod-privileged.yaml
# I can update privileged pods now
kubectl label pod nginx-privileged x=y


info 'Apply mutating psp-user-group ClusterAdmissionPolicy'
apply_policy $DATADIR/policy-psp-user-group.yaml
# Policy should mutate pods
kubectl run pause-user-group --image k8s.gcr.io/pause
kubectl wait --for=condition=Ready pod pause-user-group
kubectl get pods pause-user-group -o json | jq -e ".spec.containers[].securityContext.runAsUser==1000"
kubectl delete -f $DATADIR/policy-psp-user-group.yaml


info 'Launch & scale second policy server'
kubectl apply -f $DATADIR/policy-server.yaml
kubectl wait policyserver e2e-tests --for=condition=ServiceReconciled
kubectl patch policyserver e2e-tests --type=merge -p '{"spec": {"replicas": 2}}'
wait_rollout -n kubewarden deployment/policy-server-e2e-tests
kubectl delete -f $DATADIR/policy-server.yaml


# Cleanup
kubectl delete pod nginx-privileged nginx-unprivileged pause-user-group --ignore-not-found
