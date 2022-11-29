## How I use it

# Alias for runner (docker wrapper for validator)
ln -s $PWD/runner ~/bin/v

# Build test container
```
# You need build.suse.de access because of certificates for now
v build
```

# Run tests
```
# create k3d (-p platform) cluster, install kubewarden (-t test), don't delete cluster (-k) 
# it creates cluster-XXX (cluster ID) directory which we use later
# only -t test parameter is required here
v run -t kubewarden -k \
    -p k3d \
    -e controller=1.2.4 \
    -e defaults=1.2.5 \
    -e controller_image=latest \
    -e policyserver_image=ghcr.io/kubewarden/policy-server:v1.3.0

# list existing clusters - if status blinks cluster is up. They are sorted by creation time.
v

# run base tests on this cluster
v cluster-XXX -t e2etest
```

# Create your own test.
```
# tests/thetest.sh
step 'the test'

info 'check namespaces'
run -0 kubectl get ns
[ $status -eq 0 ]
echo $output | grep default
echo $output | grep kube-system
```

# Play inside this cluster
```

# debug problems or hack on the cluster
```bash
v cluster-XXX # opens interactive shell (ctrl-c is blocked here)
k get pods -A
exit
```

# Clean up
```
# delete all running cluster-XXX clusters
v run -R

# cleanup containers and images
v clean
```
