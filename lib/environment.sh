# Output selected variables
# Used to save information about test runs

echo "TIMESTAMP=$(date '+%s')"
echo "SUFFIX=$SUFFIX"
echo "PLATFORM=$PLATFORM"
echo "PARAMETERS=$*"
in_container && echo "CONTAINER_ID=$CONTAINER_ID"
[ -v UPGRADE ] && echo "UPGRADE=$UPGRADE"
[ -v INCIDENT_RPM ] && echo "INCIDENT_RPM=$INCIDENT_RPM"
[ -v INCIDENT_REG ] && echo "INCIDENT_REG=$INCIDENT_REG"
[ -v OS_AUTH_URL ] && echo "OS_AUTH_URL=$OS_AUTH_URL"
[ -v OS_PROJECT_NAME ] && echo "OS_PROJECT_NAME=$OS_PROJECT_NAME"
[ -v GH_VERSION ] && echo "GH_VERSION=$GH_VERSION"
echo "###"
