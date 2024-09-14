#!/usr/bin/env bash
set -euo pipefail

export CRD=$2
SOURCEDIR="$1"
TARGETDIR="$1/resources_${CRD#*/}"

# Copy files to versioned directory
mkdir -p $TARGETDIR
cp -a $SOURCEDIR/*.yaml $TARGETDIR

# There are 2 implementations of yq, from mikefarah and kislyuk
# yq_kislyuk=(yq -i -Y '.apiVersion = env.CRD')
# yq_mikefarah=(yq eval -i '.apiVersion = env(CRD)')

# Github runners default to mikefarah, let's support both for local runs
# yq --version | grep -q mikefarah && yqcmd=("${yq_mikefarah[@]}") || yqcmd=("${yq_kislyuk[@]}")

# Replace apiVersion: policies.kubewarden.io/* -> policies.kubewarden.io/v1
# grep -rlZ "apiVersion: policies.kubewarden.io" "$TARGETDIR" | xargs -0 -I {} "${yqcmd[@]}" {}

grep -rlZ "apiVersion: policies.kubewarden.io" "$TARGETDIR" | xargs -0 -I {} yq -i '.apiVersion = env(CRD)' {}
