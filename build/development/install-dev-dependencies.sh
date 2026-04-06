#!/bin/bash
# Install Dockside non-Docker system dependencies.
# Run as root. Assumes apt-get update has already been called (or call it here for standalone use).
# Used by the Dockerfile and can be run directly to prepare a local development environment.

set -e

apt-get -y --no-install-recommends --no-install-suggests install \
    sudo \
    nginx libnginx-mod-http-perl \
    wamerican \
    bind9 dnsutils \
    perl libjson-perl libjson-xs-perl liburi-perl libexpect-perl libtry-tiny-perl \
        libterm-readkey-perl libcrypt-rijndael-perl libmojolicious-perl \
    libyaml-libyaml-perl \
    libio-async-perl \
    python3-venv \
    acl \
    s6 \
    jq \
    kmod \
    ripgrep \
    logrotate cron- bcron- exim4-
