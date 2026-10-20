#!/bin/bash
# Builds this folder's image.
#   ./build.sh [--push | --multiarch] [TAG]
# --push pushes the image after building it. --multiarch builds for amd64 and arm64 and pushes
# in one step (it needs a buildx builder that can build both). TAG defaults to latest.
set -euo pipefail
cd "$(dirname "$0")"

image=ghcr.io/newsnowlabs/dockside/example/images/hugo
mode=''
case ${1:-} in --push | --multiarch) mode=$1; shift ;; esac
tag=${1:-latest}

if [[ $mode == --multiarch ]]; then
  docker buildx build --platform linux/amd64,linux/arm64 --push -t "$image:$tag" .
else
  docker build -t "$image:$tag" .
  [[ $mode != --push ]] || docker push "$image:$tag"
fi
