ARG NODE_VERSION=14
ARG ALPINE_VERSION=3.14

FROM node:${NODE_VERSION}-alpine${ALPINE_VERSION} as theia-build

RUN apk update && \
    apk add --no-cache make gcc g++ python3 libsecret-dev s6 curl file patchelf bash dropbear jq

ARG OPT_PATH
ARG TARGETPLATFORM

# Create:
# - a BASH_ENV script targeting the desired Theia version for the platform
#   that sets the THEIA_VERSION and THEIA_PATH variables correctly for each platform
#   and changes to the Theia build directory (once it exists);
# - a theia-exec wrapper script used to run the BASH_ENV script before running Theia
#   in development builds of Theia ('theia-build' and 'theia' build stages/targets).
#
# We will set bash as the build shell to allow the BASH_ENV script to be executed,
# every time a command is RUN and bash is spawned.
#
ENV BASH_ENV=/tmp/theia-bash-env

# Some but not all needed wstunnel binaries are published on https://github.com/erebe/wstunnel.
# Others we have had to compile from source. To ensure build reliability/reproducibility, we here
# obtain wstunnel binaries from the Dockside Google Cloud Storage bucket. wstunnel is published
# under https://github.com/erebe/wstunnel/blob/master/LICENSE.
RUN if [ "${TARGETPLATFORM}" = "linux/amd64" ]; then \
      THEIA_VERSION=1.40.0; \
      WSTUNNEL_BINARY="https://storage.googleapis.com/dockside/wstunnel/v6.0/wstunnel-v6.0-linux-x64"; \
    elif [ "${TARGETPLATFORM}" = "linux/arm64" ]; then \
      THEIA_VERSION=1.40.0; \
      WSTUNNEL_BINARY="https://storage.googleapis.com/dockside/wstunnel/v6.0/wstunnel-v6.0-linux-arm64"; \
    elif [ "${TARGETPLATFORM}" = "linux/arm/v7" ]; then \
      THEIA_VERSION=1.35.0; \
      WSTUNNEL_BINARY="https://storage.googleapis.com/dockside/wstunnel/v6.0/wstunnel-v6.0-linux-armv7"; \
    else \
      echo "Build error: Unsupported architecture '$TARGETPLATFORM'" >&2; \
      exit 1; \
    fi; \
    echo "export WSTUNNEL_BINARY=$WSTUNNEL_BINARY" >$BASH_ENV; \
    echo "export THEIA_VERSION=$THEIA_VERSION" >>$BASH_ENV; \
    echo "export THEIA_PATH=$OPT_PATH/ide/theia/theia-$THEIA_VERSION" >>$BASH_ENV; \
    echo 'echo THEIA_VERSION=$THEIA_VERSION THEIA_PATH=$THEIA_PATH' >>$BASH_ENV; \
    echo 'echo WSTUNNEL_BINARY=$WSTUNNEL_BINARY' >>$BASH_ENV; \
    echo 'echo TARGETPLATFORM=$TARGETPLATFORM' >>$BASH_ENV; \
    echo '[ -d $THEIA_PATH/theia ] && cd $THEIA_PATH/theia || true' >>$BASH_ENV; \
    echo -e '#!/bin/bash\n\nexec "$@"\n' >/tmp/theia-exec && chmod 755 /tmp/theia-exec; \
    . $BASH_ENV

# The BASH_ENV script will be executed prior to running all other RUN commands from here-on.
# The THEIA_VERSION and THEIA_PATH variables will thus be set correctly for each platform,
# (including after running /tmp/theia-exec).
SHELL ["/bin/bash", "-c"]

ADD ./ide/theia build/development/elf-patcher.sh /tmp/build/ide/theia

RUN mkdir -p $THEIA_PATH && \
    cp -a /tmp/build/ide/theia/$THEIA_VERSION/build $THEIA_PATH/theia && \
    cp -a /tmp/build/ide/theia/$THEIA_VERSION/bin $THEIA_PATH/

# Build Theia
RUN PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=1 && \
    PUPPETEER_SKIP_DOWNLOAD=1 && \
    NODE_OPTIONS="--max_old_space_size=4096" && \
    yarn config set network-timeout 600000 -g && yarn

# Default diagnostics entrypoint for this stage
# (and the next, which inherits it)
ENTRYPOINT ["/tmp/theia-exec", "node", "./src-gen/backend/main.js", "./", "--hostname", "0.0.0.0", "--port", "3131"]

FROM theia-build as theia-clean

RUN yarn autoclean --init && \
    echo '*.ts' >> .yarnclean && \
    echo '*.ts.map' >> .yarnclean && \
    echo '*.tsx' >> .yarnclean && \
    echo '*.spec.*' >> .yarnclean && \
    echo '*.js.map' >> .yarnclean && \
    yarn autoclean --force && \
    yarn cache clean && \
    find lib -name '*.js.map' -delete && \
    rm -rf patches && \
    rm -rf node_modules/puppeteer/.local-chromium

# Patch all binaries and dynamic libraries for full portability.

FROM theia-clean as theia-findelfs

ENV BINARIES="node busybox s6-svscan curl dropbear dropbearkey jq"

RUN /tmp/build/ide/theia/elf-patcher.sh --findelfs

FROM theia-findelfs as theia

# The version of rg installed by the Theia build on linux/arm/v7
# depends on libs that are not available on Alpine on this platform.
# Workaround this by overwriting it with Alpine's own rg.
ARG TARGETPLATFORM
RUN if [ "$TARGETPLATFORM" = "linux/arm/v7" ]; then \
      apk add --no-cache ripgrep; \
      cp $(which rg) $(find -name rg); \
    fi

RUN /tmp/build/ide/theia/elf-patcher.sh --patchelfs && \
    cd $THEIA_PATH/bin && \
    ln -sf busybox sh && \
    ln -sf busybox su && \
    ln -sf busybox pgrep && \
    curl -SsL -o wstunnel $WSTUNNEL_BINARY && chmod 755 wstunnel

# Default diagnostics entrypoint for this stage (uses patched node)
ENTRYPOINT ["/tmp/theia-exec", "../bin/node", "./src-gen/backend/main.js", "/root", "--hostname", "0.0.0.0", "--port", "3131"]

################################################################################
# DOWNLOAD AND INSTALL DEVELOPMENT VSIX PLUGINS
#

FROM alpine as vsix-plugins

COPY build/development/install-vsix.sh /root/install-vsix.sh

RUN apk update && \
    apk add --no-cache curl && \
    /root/install-vsix.sh

################################################################################
# BUILD DEVELOPMENT VSIX PLUGINS DEPENDENCIES
# - libperl-languageserver-perl, libcompiler-lexer-perl, libanyevent-aio-perl

FROM debian:bullseye as vsix-plugins-deps

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

FROM node:16-bullseye as dockside-1

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
    apt-get -y install \
        apt-transport-https ca-certificates \
        curl \
        gnupg2 && \
    curl -fsSL https://download.docker.com/linux/debian/gpg | apt-key add - && \
    echo "deb https://download.docker.com/linux/debian buster stable" >/etc/apt/sources.list.d/docker.list && \
    apt-get update && \
    apt-get -y install \
    sudo \
    nginx-light libnginx-mod-http-perl \
    wamerican \
    bind9 dnsutils \
    docker-ce docker-ce-cli containerd.io gcc- \
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

RUN apt-get -y install \
        libfile-find-rule-perl libmoose-perl libcoro-perl libjson-perl libjson-xs-perl libdata-dump-perl libterm-readline-gnu-perl \
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

FROM dockside-1 as dockside
LABEL maintainer="Struan Bartlett <struan.bartlett@NewsNow.co.uk>"

ARG DEBIAN_FRONTEND=noninteractive

ARG OPT_PATH
ARG THEIA_PATH=$OPT_PATH/ide/theia
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
COPY --from=theia /tmp/theia-bash-env /tmp/theia-bash-env

################################################################################
# COPY REMAINING GIT REPO CONTENTS TO THE IMAGE
#
COPY --chown=$USER:$USER . $HOME/$APP/

USER $USER
WORKDIR $HOME
RUN cp -a ~/$APP/build/development/dot-theia .theia && \
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
RUN . /tmp/theia-bash-env && \
    mkdir -p $OPT_PATH/bin $OPT_PATH/host && \
    cp -a $HOME/$APP/app/scripts/container/launch.sh $OPT_PATH/bin/ && \
    ln -sfr $OPT_PATH/bin/launch.sh $OPT_PATH/launch.sh && \
    cp -a $HOME/$APP/app/server/assets/ico/favicon.ico $THEIA_PATH/theia/lib/ && \
    ln -sf $THEIA_PATH/bin/launch-ide.sh $OPT_PATH/bin/launch-ide.sh && \
    ln -sfr $THEIA_PATH $OPT_PATH/theia && \
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
