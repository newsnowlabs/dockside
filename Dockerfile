# syntax=docker/dockerfile:1.3-labs

ARG NODE_VERSION=20
ARG ALPINE_VERSION=3.19

################################################################################
# SET UP 'BASE' BUILD ENVIRONMENT
#

FROM alpine:${ALPINE_VERSION} AS base

ARG OPT_PATH
ARG TARGETPLATFORM

# Create:
# - a BASH_ENV script targeting the desired versions of IDE for the platform,
#   that sets environment variables correctly and changes to the Theia build directory (once it exists);
# - a theia-exec wrapper script used to run the BASH_ENV script before running Theia
#   in development builds of Theia ('theia-build' and 'theia' build stages/targets).
#
# We will set bash as the build shell to allow the BASH_ENV script to be executed,
# every time a command is RUN and bash is spawned.
#
ENV BASH_ENV=/tmp/dockside/bash-env

# Some but not all needed wstunnel binaries are published on https://github.com/erebe/wstunnel.
# Others we have had to compile from source. To ensure build reliability/reproducibility, we here
# obtain wstunnel binaries from the Dockside Google Cloud Storage bucket. wstunnel is published
# under https://github.com/erebe/wstunnel/blob/master/LICENSE.
RUN <<EOF
if [ "${TARGETPLATFORM}" = "linux/amd64" ]; then
    THEIA_VERSION="1.56.0"
    WSTUNNEL_BINARY="https://storage.googleapis.com/dockside/wstunnel/v6.0/wstunnel-v6.0-linux-x64"
    OPENVSCODE_VERSION="1.96.4"
    OPENVSCODE_BINARY="https://github.com/gitpod-io/openvscode-server/releases/download/openvscode-server-v$OPENVSCODE_VERSION/openvscode-server-v$OPENVSCODE_VERSION-linux-x64.tar.gz"
elif [ "${TARGETPLATFORM}" = "linux/arm64" ]; then
    THEIA_VERSION="1.56.0"
    WSTUNNEL_BINARY="https://storage.googleapis.com/dockside/wstunnel/v6.0/wstunnel-v6.0-linux-arm64"
    OPENVSCODE_VERSION="1.96.4"
    OPENVSCODE_BINARY="https://github.com/gitpod-io/openvscode-server/releases/download/openvscode-server-v$OPENVSCODE_VERSION/openvscode-server-v$OPENVSCODE_VERSION-linux-arm64.tar.gz"
elif [ "${TARGETPLATFORM}" = "linux/arm/v7" ]; then
    THEIA_VERSION="1.35.0"
    THEIA_BUILD_EXTRA_PACKAGES="ripgrep"
    WSTUNNEL_BINARY="https://storage.googleapis.com/dockside/wstunnel/v6.0/wstunnel-v6.0-linux-armv7"
    OPENVSCODE_VERSION="1.96.4"
    OPENVSCODE_BINARY="https://github.com/gitpod-io/openvscode-server/releases/download/openvscode-server-v$OPENVSCODE_VERSION/openvscode-server-v$OPENVSCODE_VERSION-linux-armhf.tar.gz"
    OPENVSCODE_BUILD_DEBIAN_EXTRA_PACKAGES="libatomic1"
else
    echo "Build error: Unsupported architecture '$TARGETPLATFORM'" >&2;
    exit 1;
fi

mkdir -p $(dirname $BASH_ENV)

cat <<_EOE_ >$BASH_ENV
export TARGETPLATFORM="$TARGETPLATFORM"

export WSTUNNEL_BINARY="$WSTUNNEL_BINARY"

export THEIA_VERSION="$THEIA_VERSION"
export THEIA_PATH="$OPT_PATH/ide/theia/theia-$THEIA_VERSION"
export THEIA_BUILD_PATH="/theia"
export THEIA_BUILD_EXTRA_PACKAGES="$THEIA_BUILD_EXTRA_PACKAGES"

export OPENVSCODE_VERSION="$OPENVSCODE_VERSION"
export OPENVSCODE_BINARY="$OPENVSCODE_BINARY"
export OPENVSCODE_BUILD_DEBIAN_EXTRA_PACKAGES="$OPENVSCODE_BUILD_DEBIAN_EXTRA_PACKAGES"

echo "Running command with environment:"
echo "- TARGETPLATFORM=\$TARGETPLATFORM"
echo "- WSTUNNEL_BINARY=\$WSTUNNEL_BINARY"
echo "- THEIA_VERSION=\$THEIA_VERSION THEIA_BUILD_PATH=\$THEIA_BUILD_PATH THEIA_PATH=\$THEIA_PATH"
echo "- OPENVSCODE_BINARY=\$OPENVSCODE_BINARY"

### [ -d \$THEIA_BUILD_PATH ] && cd \$THEIA_BUILD_PATH || true
_EOE_

cat <<'_EOE_' >/tmp/dockside/theia-exec && chmod 755 /tmp/dockside/theia-exec
#!/bin/bash

[ -d $THEIA_BUILD_PATH ] && cd $THEIA_BUILD_PATH || true

exec "$@"
_EOE_
EOF

FROM node:${NODE_VERSION}-alpine${ALPINE_VERSION} AS theia-build

COPY --from=base /tmp/dockside /tmp/dockside
ENV BASH_ENV=/tmp/dockside/bash-env

RUN apk update && \
    apk add --no-cache make gcc g++ python3 libsecret-dev s6 curl file patchelf bash dropbear jq \
    git openssh-client-default

# The BASH_ENV script will be executed prior to running all other RUN commands from here-on.
# The THEIA_VERSION and THEIA_PATH variables will thus be set correctly for each platform,
# (including after running /tmp/theia-dockside/exec).
SHELL ["/bin/bash", "-c"]

ADD ./ide/theia /tmp/build/ide/theia

RUN mkdir -p $THEIA_BUILD_PATH && \
    cp -a /tmp/build/ide/theia/$THEIA_VERSION/build/* $THEIA_BUILD_PATH

# Build Theia
RUN export \
        PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=1 \
        PUPPETEER_SKIP_DOWNLOAD=1 \
    && \
    cd $THEIA_BUILD_PATH && \
    yarn config set network-timeout 600000 -g && yarn

# Default diagnostics entrypoint for this stage
# (and the next, which inherits it)
# Matches $THEIA_BUILD_PATH
ENTRYPOINT ["/tmp/dockside/theia-exec", "node", "./src-gen/backend/main.js", "./", "--hostname", "0.0.0.0", "--port", "3131"]

FROM theia-build AS theia-clean

RUN cd $THEIA_BUILD_PATH && \
    echo '*.ts' >> .yarnclean && \
    echo '*.ts.map' >> .yarnclean && \
    echo '*.tsx' >> .yarnclean && \
    echo '*.spec.*' >> .yarnclean && \
    echo '*.js.map' >> .yarnclean && \
    echo '*.tsbuildinfo' >>.yarnclean && \
    echo '*.md' >>.yarnclean && \
    yarn autoclean --force && \
    yarn cache clean && \
    find lib -name '*.js.map' -delete && \
    find lib -name '*.js.map.gz' -delete && \
    rm -rf patches && \
    rm -rf node_modules/puppeteer/.local-chromium

# Patch all binaries and dynamic libraries for full portability.
FROM theia-clean AS theia

ARG OPT_PATH

# The version of rg installed by the Theia build on linux/arm/v7
# depends on libs that are not available on Alpine on this platform.
# Workaround this by overwriting it with Alpine's own rg.
# ARG TARGETPLATFORM
RUN if [ "$TARGETPLATFORM" = "linux/arm/v7" ]; then \
      apk add --no-cache ripgrep; \
      cp $(which rg) $(find $THEIA_BUILD_PATH -name rg); \
    fi

ADD build/development/make-bundelf-bundle.sh /tmp/build/ide/theia

RUN export \
        BUNDELF_BINARIES="node busybox s6-svscan curl dropbear dropbearkey jq /usr/libexec/git-core/git /usr/libexec/git-core/git-remote-http ssh ssh-add ssh-agent ssh-keyscan" \
        BUNDELF_DYNAMIC_PATHS="$THEIA_BUILD_PATH" \
        BUNDELF_CODE_PATH="$THEIA_PATH" \
        BUNDELF_LIBPATH_TYPE="relative" \
        BUNDELF_MERGE_BINDIRS="1" && \
    /tmp/build/ide/theia/make-bundelf-bundle.sh --bundle && \
    cd $THEIA_PATH/bin && \
    ln -sf busybox sh && \
    ln -sf busybox su && \
    ln -sf busybox pgrep && \
    ln -sf git git-clone && \
    ln -sf git-remote-http git-remote-https && \
    cp -a /etc/ssl/certs $THEIA_PATH/ && \
    curl -SsL -o wstunnel $WSTUNNEL_BINARY && chmod 755 wstunnel && \
    cp -a /tmp/build/ide/theia/$THEIA_VERSION/bin/* $THEIA_PATH/bin && \
    cd $THEIA_PATH/.. && \
    ln -sf theia-$THEIA_VERSION latest

# Default diagnostics entrypoint for this stage (uses relocatable node and Theia, loses BASH_ENV build environment)
ENV BASH_ENV=""
WORKDIR $OPT_PATH/ide/theia/latest/theia
ENTRYPOINT ["../bin/node", "./src-gen/backend/main.js", "/root", "--hostname", "0.0.0.0", "--port", "3131"]

################################################################################
# DOWNLOAD AND BUILD OPENVSCODE
#
FROM debian AS openvscode

ARG OPT_PATH

# The BASH_ENV script will be executed prior to running all other RUN commands from here-on.
COPY --from=base /tmp/dockside /tmp/dockside
ENV BASH_ENV=/tmp/dockside/bash-env
SHELL ["/bin/bash", "-c"]

RUN apt update && \
    apt -y --no-install-recommends --no-install-suggests install \
        curl ca-certificates patchelf bsdextrautils file \
        $OPENVSCODE_BUILD_DEBIAN_EXTRA_PACKAGES

RUN curl -L "$OPENVSCODE_BINARY" | tar xz -C / && \
    mv -v /openvs* /openvscode

ADD ./ide/openvscode/bin /tmp/bin
ADD build/development/make-bundelf-bundle.sh /tmp/

RUN export \
        BUNDELF_BINARIES="" \
        BUNDELF_DYNAMIC_PATHS="/openvscode" \
        BUNDELF_CODE_PATH="$OPT_PATH/ide/openvscode/$OPENVSCODE_VERSION" \
        BUNDELF_LIBPATH_TYPE="relative" && \
    /tmp/make-bundelf-bundle.sh --bundle && \
    cd $BUNDELF_CODE_PATH/.. && \
    ln -s $OPENVSCODE_VERSION latest && \
    cp -a /tmp/bin $OPENVSCODE_VERSION/

# Default diagnostics entrypoint for this stage (uses relocatable node and openvscode, loses BASH_ENV build environment)
ENV BASH_ENV=""
WORKDIR $OPT_PATH/ide/openvscode/latest/openvscode
ENTRYPOINT ["./node", "./out/server-main.js", "--host", "0.0.0.0", "--port", "3131", "--without-connection-token"]

################################################################################
# DOWNLOAD AND INSTALL DEVELOPMENT VSIX PLUGINS
#

FROM alpine AS vsix-plugins

COPY build/development/install-vsix.sh /root/install-vsix.sh

RUN apk update && \
    apk add --no-cache curl && \
    /root/install-vsix.sh

################################################################################
# BUILD DEVELOPMENT VSIX PLUGINS DEPENDENCIES
# - libperl-languageserver-perl, libcompiler-lexer-perl, libanyevent-aio-perl

FROM debian:bullseye AS vsix-plugins-deps

ARG DEBIAN_FRONTEND=noninteractive

# Install dependencies
RUN apt-get update && apt-get -y install \
   sudo procps vim less curl locales \
   libfile-find-rule-perl libmoose-perl libcoro-perl libjson-perl libjson-xs-perl libmodule-build-xsutil-perl \
   libdata-dump-perl \
   git dh-make-perl fakeroot

RUN sudo bash -c 'echo NewsNow.co.uk >/etc/mailname'

# Create build user 'newsnow' (could be anything)
RUN useradd -l -U -u 1000 -md /home/newsnow -s /bin/bash newsnow && echo "newsnow ALL=(ALL) NOPASSWD: ALL" >/etc/sudoers.d/newsnow
USER newsnow
WORKDIR /home/newsnow

RUN mkdir -p /home/newsnow/.cpan

# Configure CPAN
COPY --chown=newsnow:newsnow build/development/cpan/MyConfig.pm /home/newsnow/.cpan/CPAN/MyConfig.pm

# BUILD libcompiler-lexer-perl_*.deb
RUN git clone https://github.com/goccy/p5-Compiler-Lexer && cd ~/p5-Compiler-Lexer && rm -rf .git && dh-make-perl make . || true
RUN cd ~/p5-Compiler-Lexer && DEB_BUILD_OPTIONS=nocheck fakeroot ./debian/rules binary
RUN sudo dpkg -i libcompiler-lexer-perl_*.deb

# BUILD libanyevent-aio-perl
RUN PERL_YAML_BACKEND=YAML::XS cpan2deb AnyEvent::AIO && sudo dpkg -i libanyevent-aio-perl_1.1-1_all.deb

# BUILD Perl::LanguageServer
# RUN cpan2deb Perl::LanguageServer --version 2.1.0
RUN git clone https://github.com/NewsNow/Perl-LanguageServer.git && cd ~/Perl-LanguageServer && rm -rf .git && dh-make-perl make . || true
RUN cd ~/Perl-LanguageServer && fakeroot ./debian/rules binary

################################################################################
# MAIN DOCKSIDE BUILD
#

FROM node:20-bullseye AS dockside-1

ARG DEBIAN_FRONTEND=noninteractive

ARG OPT_PATH
ARG USER=dockside
ARG APP=dockside
ARG HOME=/home/newsnow

################################################################################
# USE BASH SHELL
#
SHELL ["/bin/bash", "-c"]

################################################################################
# DOCKER INSTALL DEPENDENCIES
# (See https://docs.docker.com/install/linux/docker-ce/debian/)
#
RUN apt-get update && \
    apt-get -y upgrade && \
    apt-get -y --no-install-recommends --no-install-suggests install \
        apt-transport-https ca-certificates \
        curl \
        gnupg2 && \
    curl -fsSL https://download.docker.com/linux/debian/gpg | apt-key add - && \
    echo "deb https://download.docker.com/linux/debian $(cat /etc/os-release | grep VERSION_CODENAME | cut -d '=' -f2) stable" >/etc/apt/sources.list.d/docker.list && \
    apt-get update && \
    apt-get -y --no-install-recommends --no-install-suggests install \
    sudo \
    nginx-light libnginx-mod-http-perl \
    wamerican \
    bind9 dnsutils \
    docker-ce docker-ce-cli docker-buildx-plugin containerd.io gcc- \
    perl libjson-perl libjson-xs-perl liburi-perl libexpect-perl libtry-tiny-perl libterm-readkey-perl libcrypt-rijndael-perl libmojolicious-perl \
    python3-pip \
    acl \
    s6 \
    jq \
    kmod \
    logrotate cron- bcron- exim4-

################################################################################
# DEVELOPMENT DEPENDENCIES
#
# Perl::LanguageServer dependencies

COPY --from=vsix-plugins-deps /home/newsnow/*.deb /tmp/vsix-deps/

RUN apt-get -y --no-install-recommends --no-install-suggests install \
        libfile-find-rule-perl libmoose-perl libcoro-perl libjson-perl libjson-xs-perl libdata-dump-perl libterm-readline-gnu-perl \
        libio-aio-perl \
        git tig perltidy \
        procps vim less curl locales \
        /tmp/vsix-deps/*.deb && \
    rm -rf /tmp/vsix-deps

################################################################################
# GCLOUD SDK: https://cloud.google.com/sdk/docs/quickstart-debian-ubuntu
#
# RUN echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] http://packages.cloud.google.com/apt cloud-sdk main" | tee -a /etc/apt/sources.list.d/google-cloud-sdk.list && curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key --keyring /usr/share/keyrings/cloud.google.gpg  add - && apt-get update && apt-get -y install google-cloud-sdk

################################################################################
# CREATE USER, AND HOME AND LOG DIRECTORIES
#
# Create the user, add to the docker and bind groups, set home directory
# to $HOME and the shell to /bin/bash
#
RUN useradd -l -U -m $USER -s /bin/bash -d $HOME && \
    usermod -a -G docker,bind -d $HOME -s /bin/bash $USER && \
    mkdir -p $HOME/$APP /var/log/$APP && \
    touch /var/log/$APP/$APP.log && \
    chown -R $USER.$USER $HOME /var/log/$APP/$APP.log

################################################################################
# DEHYDRATED SETUP
#
USER $USER
COPY --chown=$USER:$USER dehydrated $HOME/$APP/dehydrated/

################################################################################
# VUE CLIENT INSTALL
#
COPY --chown=$USER:$USER app/client $HOME/$APP/app/client/
WORKDIR $HOME/$APP/app/client
RUN npm install && npm run build && npm cache clean --force

################################################################################
# MKDOCS INSTALL
#
COPY --chown=$USER:$USER app/server/assets $HOME/$APP/app/server/assets/
COPY --chown=$USER:$USER docs $HOME/$APP/docs/
COPY --chown=$USER:$USER mkdocs.yml $HOME/$APP/
WORKDIR $HOME/$APP
RUN pip3 install --no-warn-script-location mkdocs mkdocs-material==8.4.4 && ~/.local/bin/mkdocs build && rm -rf ~/.cache/pip

FROM dockside-1 AS dockside
LABEL maintainer="Struan Bartlett <struan.bartlett@NewsNow.co.uk>"

ARG DEBIAN_FRONTEND=noninteractive

ARG OPT_PATH
ARG THEIA_PATH=$OPT_PATH/ide/theia
ARG VSCODE_PATH=$OPT_PATH/ide/openvscode
ARG USER=dockside
ARG APP=dockside
ARG HOME=/home/newsnow

################################################################################
# INSTALL DEVELOPMENT VSIX PLUGINS
#
# (disabled as there are currently no VSIX extensions needing to be embedded in the image)
# COPY --from=vsix-plugins --chown=$USER:$USER /root/theia-plugins $HOME/theia-plugins/

################################################################################
# THEIA INTEGRATION
#
COPY --from=theia $THEIA_PATH $THEIA_PATH/
COPY --from=base /tmp/dockside /tmp/dockside
COPY --from=openvscode ${VSCODE_PATH} ${VSCODE_PATH}/

################################################################################
# COPY REMAINING GIT REPO CONTENTS TO THE IMAGE
#
COPY --chown=$USER:$USER . $HOME/$APP/

USER $USER
WORKDIR $HOME
RUN cp -a ~/$APP/build/development/dot-theia .vscode && \
    cd ~ && ln -s .vscode .theia && cd - && \
    ln -s ~/$APP/build/development/perltidyrc ~/.perltidyrc && \
    ln -s ~/$APP/build/development/vetur.config.js ~/

################################################################################
# Cause the creation of a volume at /opt/dockside.
#
VOLUME $OPT_PATH

# Create a separate volume for host-specific data to be shared
# read-only with devtainers
VOLUME $OPT_PATH/host

################################################################################
# INITIALISE /opt/dockside/bin
#
# launch.sh will overwrite them on launch;
# but when launching a container within the app,
# the inner container will have its own /opt/dockside, and will expect to access these scripts
# before its own launch.sh runs.
#
USER root
RUN . /tmp/dockside/bash-env && \
    mkdir -p $OPT_PATH/bin $OPT_PATH/host && \
    cp -a $HOME/$APP/app/scripts/container/launch.sh $OPT_PATH/bin/ && \
    ln -sfr $OPT_PATH/bin/launch.sh $OPT_PATH/launch.sh && \
    if [ "$THEIA_VERSION" = "1.35.0" ]; then cp -a $HOME/$APP/app/server/assets/ico/favicon.ico $THEIA_PATH/theia/lib/; else cp -a $HOME/$APP/app/server/assets/ico/favicon.ico $THEIA_PATH/theia/lib/frontend/; fi && \
    # ln -sf $THEIA_PATH/bin/launch-ide.sh $OPT_PATH/bin/launch-ide.sh && \
    ln -sfr $THEIA_PATH $OPT_PATH/theia && \
    ln -sfr $THEIA_PATH $OPT_PATH/system && \
    ln -sf $HOME/$APP/app/scripts/entrypoint.sh /entrypoint.sh && \
    ln -sf $HOME/$APP/app/server/bin/password-wrapper /usr/local/bin/password && \
    ln -sf $HOME/$APP/app/server/bin/upgrade /usr/local/bin/upgrade && \
    chown -R root.root $OPT_PATH/bin/

################################################################################
# CLEAN UP
RUN apt-get clean && rm -rf /var/cache/apt/* && rm -rf /var/lib/apt/lists/* && rm -rf /tmp/*

################################################################################
# LAUNCH
#
ENTRYPOINT ["/entrypoint.sh"]
