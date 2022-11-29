# ==================================================================================================
# Images #
#
# sample: -e controller_image=v1.3.0 -e policyserver_image=ghcr.io/kubewarden/kubewarden-controller:latest
# priority:
#	-e parameter > magic dir > from helm chart (default)
# parameters:
#   -e controller_image=<value>
# 	-e policyserver_image=<value>
# values:
#	=../magic/image.tar - local file
# 	=v1.3.0 (tag) - use ghcr.io/kubewarden repo
# 	=ghcr.io/kubewarden/kubewarden-controller (url without tag - use latest)
# 	=ghcr.io/kubewarden/kubewarden-controller:latest (full url)
# magic:
#	create symlink named kubewarden-(controller|policyserver)-image in ./magic directory
#	which points to image tar you want to use in the kubewarden deployment
#
# ==================================================================================================
# Charts #
#
# sample: -e crds=1.2.2 -e controller=1.2.2
# priority:
#	-e parameter > magic dir > latest available online (default)
# parameters:
#	-e crds=<version> -e controller=<version> -e defaults=<version>
# magic:
# 	extract chart in directory ./magic/kubewarden-(crds|controller|defaults) 
#
# ==================================================================================================

# Notes:
# HELM_REPO=[./|magic|repo|url]
# helm repo add kubewarden https://charts.kubewarden.io
# -e HELM_REPO=[kubewarden|https://charts.kubewarden.io]

# Defaults
: ${IMG_REPO:=ghcr.io/kubewarden}
: ${IMG_CONTROLLER:=$IMG_REPO/kubewarden-controller}
: ${IMG_POLICYSERVER:=$IMG_REPO/policy-server}

function helm_in {
	# --reset-values --version
    helm upgrade --install --wait --namespace kubewarden --create-namespace "${@:3}" $1 $2

    # kubewarden-defaults ignore wait param, so rollout status would fail without retry (does not exist yet)
    # retry function requires full command, not a function
    [ $1 = 'kubewarden-defaults' ] && retry "kubectl rollout status -n kubewarden deployment/policy-server-default"
    return 0
}

# ==================================================================================================
# Import images

step 'Import images'

function expand_src() {
	local src=$1
	declare -nu imgurl=IMG_$2
	[[ ! "$src" =~ [:/] ]] && src=":$src"		# v1.3.0 -> :v1.3.0 (param without : or / is tag)
	[[ "$src" != */* ]] && src="$imgurl$src"	# :v1.3.0 -> ghcr.io/kw/kubewarden-controller:v1.3.0 (prepend url to param without /)
	[[ "$src" != *:* ]] && src+=":latest"		# ghcr.io/kw/kubewarden-controller -> ghcr.io/kw/kubewarden-controller:latest
	echo $src
}

controller_params=""
for name in controller policyserver; do
	# use parameter if set, otherwise look into magic dir
	declare -n src=${name}_image
	magicpath="$BASEDIR/magic/kubewarden-$name-image"

	imagefile=""
	# Load image from parameter
	if [ -v src ]; then
		if [ -f "$src" ]; then
			imagefile=$src
			imagetag=$(tar -xOf $imagefile manifest.json | jq -r 'first.RepoTags[0]' | cut -d':' -f2)
		else
			src=$(expand_src $src $name)
			imagefile=${src##*/}.tar	 # kubewarden-controller:latest
			imagetag=${src#*:}			 # latest
			skopeo copy docker://$src docker-archive:${imagefile%:*}:$src && mv ${imagefile%:*} $imagefile
		fi
	# Load image from magic path
	elif [ -L $magicpath ]; then
		imagefile=$(readlink -f $magicpath)
		# imagetag=$(basename $imagefile | sed -E 's|.*:(.*)\..*|\1|')
		imagetag=$(tar -xOf $imagefile manifest.json | jq -r 'first.RepoTags[0]' | cut -d':' -f2)
	fi

	if [ -n "$imagefile" ]; then
		info "$name image (${imagefile/$BASEDIR/.} [$imagetag])"
		k3d image import -c $CLUSTERID $imagefile

		# get tag from file name
		if [ $name == 'controller' ]; then
			controller_params+=" --set image.tag=$imagetag --set image.pullPolicy=Never"
		elif [ $name == 'policyserver' ]; then
			controller_params+=" --set policyServer.image.tag=$imagetag"
		fi
	fi

done

# ==================================================================================================
# Install Kubewarden
step 'Install Kubewarden'

helm repo update kubewarden || helm repo add kubewarden https://charts.kubewarden.io

repover_json=$(helm search repo kubewarden --devel -o json)
for name in crds controller defaults; do
	version=${!name:-} # set version from arg if available
	repover=$(jq --arg n $name '.[] | select(.name|endswith($n)).version' -r <<< "$repover_json")

	# Install from magic dir if no version arg is set
	if [[ -e "$BASEDIR/magic/kubewarden-$name" && -z "$version" ]]; then
		chartpath="$BASEDIR/magic/kubewarden-$name"
		version=$(helm show chart $chartpath | grep ^version: | cut -d' ' -f2)
	else
		: ${version:=$repover} # use latest version if not set
		chartpath="$WORKDIR/kubewarden-$name-${version}.tgz"
		[ ! -f $chartpath ] && helm pull kubewarden/kubewarden-$name --version ${version}
	fi

	info "$name ${version/$repover/$repover (latest)} [$(echo $chartpath | grep -o magic || echo pulled)]"

	# get chart parameters from generated variable name
	declare -n chart_params=${name}_params
	helm_in kubewarden-$name $chartpath ${chart_params:-}
done
