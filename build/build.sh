#!/bin/bash

IMAGE=$(basename $(pwd))
REPO="newsnowlabs/dockside"
DOCKERFILE="Dockerfile"
TAG_DATE="$(date -u +%Y%m%d%H%M%S)"
THEIA_VERSION=1.27.0
BUILDER=buildkit
PLATFORMS_DEFAULT_DEPOT="linux/amd64,linux/arm64,linux/arm/v7"

usage() {
  echo "$0: [[--stage <stage>] [--tag <tag>] [--theia <version>]] [--push|--load] [--no-cache] [--force-rm] [--progress-plain] [--repo <repo>] [--builder [depot|buildx|buildkit]] [--platform=<platforms>] | [--clean] | [--list]" >&2
  exit
}

push() {
  [ -z "$PUSH" ] && return
  
  for t in ${TAGS[@]}
  do
    docker push $t
  done
}

list() {
  local FILTERS="--filter=reference=$REPO "
  
  docker image ls $FILTERS "$@"
}

clean() {
  local IMAGES=$(list -q | sort -u)
  [ -z "$IMAGES" ] && return
  docker rmi -f $IMAGES
}

parse_commandline() {
  while true
  do
    case "$1" in
      --stage|--target) shift; STAGE="$1"; shift; continue; ;;
            --no-cache) shift; NO_CACHE="1"; continue; ;;
            --force-rm) shift; FORCE_RM="1"; continue; ;;
                 --tag) shift; TAG="$1"; shift; continue; ;;
                --repo) shift; REPO="$1"; shift; continue; ;;
      --progress-plain) shift; PROGRESS="plain"; continue; ;;
            --progress) shift; PROGRESS="$1"; shift; continue; ;;
               --theia) shift; THEIA_VERSION="$1"; shift; continue; ;;

            --builder) shift; BUILDER="$1"; shift; continue; ;;
          --platforms) shift; PLATFORMS="$1"; shift; continue; ;;
	    
               --clean) shift; clean; exit 0; ;;
           --list|--ls) shift; list "$@"; exit 0; ;;
	 
                --push) shift; PUSH="1"; ;;
                --load) shift; LOAD="1"; ;;
	      
             -h|--help) usage; ;;
                     *) break; ;;
    esac
  done
}

build_env() {
  TAG_DATE="$(date -u +%Y%m%d%H%M%S)"
  TAGS=()

  if [ -n "$TAG" ]; then
    TAGS+=("$REPO:$TAG")
  fi

  if [ -n "$STAGE" ] && [ "$STAGE" != "production" ]; then
    TAGS+=("$REPO:$STAGE")
  elif [ -z "$TAG" ]; then
    TAGS+=("$REPO:latest")
  fi

  for t in ${TAGS[@]}
  do
    DOCKER_OPTS_TAGS+=" --tag $t"
  done

  DOCKER_OPTS=()
  DOCKER_OPTS+=("--label=com.newsnow.dockside.build.date=$TAG_DATE")
  DOCKER_OPTS+=("--build-arg=OPT_PATH=/opt/dockside")
  DOCKER_OPTS+=("--build-arg=THEIA_VERSION=$THEIA_VERSION")

  [ -n "$NO_CACHE" ] && DOCKER_OPTS+=("--no-cache")
  [ -n "$FORCE_RM" ] && DOCKER_OPTS+=("--force-rm")
  [ -n "$PULL" ] && DOCKER_OPTS+=("--pull")
  [ -n "$STAGE" ] && DOCKER_OPTS+=("--target=$STAGE")
  [ -n "$PROGRESS" ] && DOCKER_OPTS+=("--progress=$PROGRESS")
  [ -n "$TAG" ] && DOCKER_OPTS+=("--label" "com.newsnow.dockside.build.tag=$TAG")
  
  if [ -n "$PLATFORMS" ]; then
    DOCKER_OPTS+=("--platform=$PLATFORMS")
  elif [ "$BUILDER" = "depot" ]; then    
    DOCKER_OPTS+=("--platform=$PLATFORMS_DEFAULT_DEPOT")
  fi
}

parse_commandline "$@"

build_env

[ -z "$DOCKER_BUILDKIT" ] && DOCKER_BUILDKIT=1
export DOCKER_BUILDKIT

case "$BUILDER" in

  buildkit)
  
    # Build using Docker Build (https://docs.docker.com/build/)

    if [[ "$PLATFORMS" =~ , ]]; then
      echo "$0: Error, --platforms=$PLATFORMS but must use --platforms=<platform> with only one platform at a time, with the '$BUILDER' builder; try changing builder or specifying only one platform; aborting" >&2
      exit -1
    fi

    docker build "${DOCKER_OPTS[@]}" $DOCKER_OPTS_TAGS -f "$DOCKERFILE" . || exit -1
    [ "$PUSH" == "1" ] && push
    ;;

  buildx)
  
    # Build using Docker Buildx (https://github.com/docker/buildx)

    [ "$PUSH" == "1" ] && DOCKER_OPTS+=("--push")
    [ "$LOAD" == "1" ] && DOCKER_OPTS+=("--load")
    
    docker buildx build "${DOCKER_OPTS[@]}" $DOCKER_OPTS_TAGS -f "$DOCKERFILE" . || exit -1
    ;;

  depot)
  
    # Build using Depot (https://depot.dev/), for building Docker images faster and smarter, in the cloud.

    [ "$PUSH" == "1" ] && DOCKER_OPTS+=("--push")
    [ "$LOAD" == "1" ] && DOCKER_OPTS+=("--load")

    if [ -z "$(which depot)" ]; then
       echo "$0: Error, depot CLI not installed (see https://depot.dev/), aborting" >&2
       exit -1
    fi
    depot build "${DOCKER_OPTS[@]}" $DOCKER_OPTS_TAGS -f "$DOCKERFILE" . || exit -1
    ;;

  *)
    echo "$0: Error, unknown builder '$BUILDER', aborting." >&2
    exit -1
    ;;

esac
