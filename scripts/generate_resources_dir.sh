#!/usr/bin/env bash
set -euo pipefail

CRD=$2
SOURCEDIR="$1"
TARGETDIR="$1/resources_${CRD#*/}"

# Copy files to versioned directory
mkdir -p $TARGETDIR
cp -a $SOURCEDIR/*.yaml $TARGETDIR

# Replace policies apiVersion with $CRD
grep -rlZ "apiVersion: policies.kubewarden.io" $TARGETDIR | xargs -0 \
	 yq -i -Y --arg c $CRD '.apiVersion = $c'
