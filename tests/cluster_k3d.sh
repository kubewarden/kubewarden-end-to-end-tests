# You has to define following:
# create & delete action
# JSON - json cluster description
# [IP_LB], IP_MASTERS, IP_WORKERES - list of addresses
# file name: cluster_${platform}.sh

# create new cluster
if [ "${1:-}" == 'create' ]; then
	k3d cluster create $CLUSTERID -s $MASTER_COUNT -a $WORKER_COUNT --wait -v /dev/mapper:/dev/mapper
	k3d kubeconfig get $CLUSTERID > "$WORKDIR/admin.conf"
fi

# delete existing cluster
if [ "${1:-}" == 'delete' ]; then
	k3d cluster delete $CLUSTERID
	return
fi

# return 0 if cluster exists otherwise non 0
if [ "${1:-}" == 'status' ]; then
	k3d cluster list $CLUSTERID &>/dev/null
	return
fi

# set variables for test handler
JSON=$(k3d cluster list $CLUSTERID -o json)
IP_LB=$(jq '.[].nodes[] | select(.role == "loadbalancer").IP.IP' -r <<< "$JSON")
readarray -t IP_MASTERS < <(jq '.[].nodes[] | select(.role == "server").IP.IP' -r <<< "$JSON")
readarray -t IP_WORKERS < <(jq '.[].nodes[] | select(.role == "agent").IP.IP' -r <<< "$JSON")
