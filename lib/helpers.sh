# Helper functions used by tests
# ==================================================================================================

# Run command until it ends successfully
function retry() {
    local cmd=$1
    local tries=${2:-10}
    local delay=${3:-30}
    local i
    for ((i=1; i<=tries; i++)); do
        timeout 25 bash -c "$cmd" && break || echo "RETRY #$i: $cmd"
        [ $i -ne $tries ] && sleep $delay || { echo "Godot: $cmd"; false; }
    done
}

# Rework of bats run command
function run() {
    local status_req=0
    if [[ $1 =~ ^-[0-9]+ ]]; then
        status_req=${1#-}
        shift
    fi
    status=0
    output=$(eval "$@" 2>&1 | tee -a $OUTPUT) || status=$?
    [ $status -eq $status_req ]
}

# ==================================================================================================
# Kubernetes specific

# Safe version of waiting for pods. Looks in kube-system ns by default
# Handles kube-api disconnects during upgrade
function wait_pods() {
    local i output
    for i in {1..20}; do
        output=$(kubectl get pods --no-headers -o wide ${@:---all-namespaces} | grep -vw Completed || echo 'Fail')
        grep -vE '([0-9]+)/\1 +Running' <<< $output || break
        [ $i -ne 20 ] && sleep 30 || { echo "Godot: pods not running"; false; }
    done
}

# Safe version of waiting for nodes
# Handles kube-api disconnects during upgrade
function wait_nodes() {
    local i output
    for i in {1..20}; do
        output=$(kubectl get nodes --no-headers ${@:-} || echo 'Fail')
        grep -vE '\bReady\b' <<< $output || break
        [ $i -ne 20 ] && sleep 30 || { echo "Godot: nodes not running"; false; }
    done
}

function wait_for    () { kubectl wait --timeout=5m "$@"; }
function wait_rollout() { kubectl rollout status --timeout=5m "$@"; }
function wait_deployment () { wait_for deployment --for=condition=available "$@"; }

# ==================================================================================================
# Functions for VMs handling

# Execute command on all nodes
nodes_run() {
    local vm
    for vm in "${IP_NODES[@]}"; do
        ssh $vm "$@" || { error "ssh $vm $@"; false; }
    done
}

# Upload file to all nodes
nodes_scp() {
    local vm
    for vm in "${IP_NODES[@]}"; do
        scp $1 $vm:/tmp/
        ssh $vm "sudo mv /tmp/$(basename $1) ${2:-.}"
    done
}

# Execute (long running) task on nodes in parallel
nodes_run_parallel() {
    unit="run-$(date +%s)"
    nodes_run "sudo systemd-run -r --unit $unit -- $1 2>&1"
    local vm
    for vm in "${IP_NODES[@]}"; do
        retry "ssh $ssh_opts $vm 'systemctl show -p SubState --value $unit | grep -vx running'" 30 60
        ssh $vm "sudo journalctl -u $unit"
        ssh $vm "systemctl show -p Result --value $unit | grep -qx success"
        ssh $vm "sudo systemctl stop $unit"
    done
}

# ==================================================================================================
# Kubewarden specific

function apply_policy() {
    kind=$(yq -er '.kind' $1)

    kubectl apply -f $1
    wait_for --for=condition="PolicyActive" $kind --all -A
    wait_rollout -n kubewarden "deployment/policy-server-default"
    wait_for --for=condition="PolicyUniquelyReachable" $kind --all -A
}

function kubefail_privileged() {
    run -1 "$@"
    echo "$output" | grep -E '^Error.*: admission webhook.*denied the request.*container is not allowed$'
}
