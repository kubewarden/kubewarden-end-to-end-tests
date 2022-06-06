#!/bin/bash

RESOURCES_DIR=$1
CRD_VERSION=$2

rm -r $RESOURCES_DIR/resources_$CRD_VERSION
mkdir $RESOURCES_DIR/resources_$CRD_VERSION

find $RESOURCES_DIR -maxdepth 1 -type f  -exec cp \{\}  $RESOURCES_DIR/resources_$CRD_VERSION \;

kubewarden_resources_files=$(grep -rl "apiVersion: policies.kubewarden.io" $RESOURCES_DIR/resouces_$CRD_VERSION)
for file in $kubewarden_resources_files 
do 
	yq --in-place -Y ".apiVersion =\"policies.kubewarden.io/$CRD_VERSION\"" $file
done
