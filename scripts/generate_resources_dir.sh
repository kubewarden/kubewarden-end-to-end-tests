#!/bin/bash

RESOURCES_DIR=$1
CRD_VERSION=$2
CRD_SUFFIX=$3

rm -r $RESOURCES_DIR/resources_$CRD_SUFFIX
mkdir $RESOURCES_DIR/resources_$CRD_SUFFIX

find $RESOURCES_DIR -maxdepth 1 -type f  -exec cp \{\}  $RESOURCES_DIR/resources_$CRD_SUFFIX \;

kubewarden_resources_files=$(grep -rl "apiVersion: policies.kubewarden.io" $RESOURCES_DIR/resources_$CRD_SUFFIX)
for file in $kubewarden_resources_files 
do 
	yq --in-place -Y ".apiVersion =\"$CRD_VERSION\"" $file
done
