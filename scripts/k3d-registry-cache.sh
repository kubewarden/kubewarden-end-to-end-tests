#!/usr/bin/env bash
# Usage: ./script [ghcr.io|appco.io ...]   (no args = all)
# Creates k3d pull-through cache registries; skips ones that already exist.
# Credentials come from GHCR_/APPCO_ USERNAME/PASSWORD env vars, or you're prompted for them.
set -euo pipefail

create() {  # name remote-url user-var pass-var
    docker container inspect "k3d-$1" &>/dev/null && { echo "k3d-$1 exists, skipping"; return; }

    [[ -n "${!3:-}" ]] || read -rp "$1 username: " "$3"
    [[ -n "${!4:-}" ]] || { read -rsp "$1 password/token: " "$4"; echo; }

    k3d registry create "$1" --no-help --image registry:3 \
        --proxy-remote-url "$2" --proxy-username "${!3}" --proxy-password "${!4}" \
        -v "/var/cache/registry/$1:/var/lib/registry"
}

# Start selected registries by default
(( $# )) || set -- ghcr.io appco.io
for r; do
    case "$r" in
        ghcr.io)  create "$r" https://ghcr.io            GHCR_USERNAME  GHCR_PASSWORD ;;
        appco.io) create "$r" https://dp.apps.rancher.io APPCO_USERNAME APPCO_PASSWORD ;;
        *) echo "unknown registry: $r" >&2; exit 1 ;;
    esac
done
