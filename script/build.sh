#!/bin/sh

DOCKER_BUILDKIT=1 docker build -t newsnowlabs/dockside:io -f Dockerfile .
