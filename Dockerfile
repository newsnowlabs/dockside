ARG NODE_VERSION=12
ARG ALPINE_VERSION=3.14

FROM node:${NODE_VERSION}-alpine${ALPINE_VERSION} as theia-build

RUN apk update && \
    apk add --no-cache make gcc g++ python3 libsecret-dev s6 curl file patchelf

ARG OPT_PATH
ARG THEIA_VERSION
ARG THEIA_PATH=$OPT_PATH/ide/theia/theia-$THEIA_VERSION

WORKDIR $THEIA_PATH/theia
ADD ./ide/theia/$THEIA_VERSION/build/ ./

# Build Theia
RUN PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=1 && NODE_OPTIONS="--max_old_space_size=4096" && yarn

FROM theia-build as theia-clean

ARG OPT_PATH
ARG THEIA_VERSION
ARG THEIA_PATH=$OPT_PATH/ide/theia/theia-$THEIA_VERSION

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
COPY build/development/elf-patcher.sh $THEIA_PATH/bin/elf-patcher.sh

FROM theia-clean as theia

ARG OPT_PATH
ARG THEIA_VERSION
ARG THEIA_PATH=$OPT_PATH/ide/theia/theia-$THEIA_VERSION

ARG BINARIES="node busybox s6-svscan curl"

RUN $THEIA_PATH/bin/elf-patcher.sh && \
    cd $THEIA_PATH/bin && \
    ln -sf busybox sh && \
    ln -sf busybox su && \
    ln -sf busybox pgrep

# Add our Theia-version-specific scripts.
ADD ./ide/theia/$THEIA_VERSION/bin/ $THEIA_PATH/bin/

################################################################################
# DOWNLOAD AND INSTALL DEVELOPMENT VSIX PLUGINS
#

FROM amd64/debian:buster as vsix-plugins

ARG DEBIAN_FRONTEND=noninteractive

COPY build/development/install-vsix.sh /root/install-vsix.sh

RUN apt-get update && \
    apt-get -y install curl && \
    /root/install-vsix.sh

################################################################################
# BUILD DEVELOPMENT VSIX PLUGINS DEPENDENCIES
# - libperl-languageserver-perl, libcompiler-lexer-perl, libanyevent-aio-perl

FROM amd64/debian:buster as vsix-plugins-deps

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
RUN cd ~/p5-Compiler-Lexer && fakeroot ./debian/rules binary
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

FROM amd64/debian:buster as Dockside
LABEL maintainer="Struan Bartlett <struan.bartlett@NewsNow.co.uk>"

ARG DEBIAN_FRONTEND=noninteractive

ARG OPT_PATH
ARG THEIA_VERSION
ARG THEIA_PATH=$OPT_PATH/ide/theia/theia-$THEIA_VERSION
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
    echo "deb [arch=amd64] https://download.docker.com/linux/debian buster stable" >/etc/apt/sources.list.d/docker.list && \
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
    logrotate cron- bcron- exim4-

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
# Install NODE DEPENDENCIES
#
# Install NVM, Node, and Yarn
#
USER $USER
WORKDIR $HOME
RUN curl -o- https://raw.githubusercontent.com/creationix/nvm/v0.33.5/install.sh | bash && \
    bash -c ". ~/.nvm/nvm.sh && nvm install 12 && rm -rf ~/.nvm/.git && nvm cache clear" && \
    echo 'export NVM_DIR="$HOME/.nvm"; [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh" # This loads nvm' >>~/.bashrc

################################################################################
# Mailname
#
# RUN sudo bash -c 'echo NewsNow.co.uk >/etc/mailname'

################################################################################
# DEHYDRATED SETUP
#
USER $USER
COPY --chown=$USER:$USER dehydrated $HOME/$APP/dehydrated/
RUN cp -aL $HOME/$APP/dehydrated/certs/sslzone/{fullchain.pem,privkey.pem} $HOME/$APP/app/server/example/certs/ || true && \
    rm -rf $HOME/$APP/dehydrated/accounts/* \
           $HOME/$APP/dehydrated/certs/sslzone/* \
           $HOME/$APP/dehydrated/chains/*

################################################################################
# DEVELOPMENT DEPENDENCIES
# 
COPY --chown=$USER:$USER build $HOME/$APP/build/

USER root
# Perl::LanguageServer dependencies
COPY --from=vsix-plugins-deps /home/newsnow/*.deb /tmp/vsix-deps/

RUN apt-get -y install \
        libfile-find-rule-perl libmoose-perl libcoro-perl libjson-perl libjson-xs-perl libdata-dump-perl libterm-readline-gnu-perl \
	git tig perltidy \
	procps vim less curl locales \
        /tmp/vsix-deps/*.deb && \
    rm -rf /tmp/vsix-deps

################################################################################
# VUE CLIENT INSTALL
#
USER $USER
COPY --chown=$USER:$USER app/client $HOME/$APP/app/client/
WORKDIR $HOME/$APP/app/client
RUN NVM_DIR="$HOME/.nvm" && \. "$NVM_DIR/nvm.sh" && npm install && npm run build && npm cache clean --force

################################################################################
# MKDOCS INSTALL
#
COPY --chown=$USER:$USER app/server/assets $HOME/$APP/app/server/assets/
COPY --chown=$USER:$USER docs $HOME/$APP/docs/
COPY --chown=$USER:$USER mkdocs.yml $HOME/$APP/
WORKDIR $HOME/$APP
RUN pip3 install --no-warn-script-location mkdocs mkdocs-material && ~/.local/bin/mkdocs build && rm -rf ~/.cache/pip

################################################################################
# INSTALL SETTINGS
#
USER $USER
WORKDIR $HOME
RUN cp -a ~/$APP/build/development/dot-theia .theia && \
    ln -s ~/$APP/build/development/perltidyrc ~/.perltidyrc

################################################################################
# INSTALL DEVELOPMENT VSIX PLUGINS
#
COPY --from=vsix-plugins --chown=$USER:$USER /root/theia-plugins $HOME/theia-plugins/

################################################################################
# THEIA INTEGRATION
#
COPY --from=theia $THEIA_PATH $THEIA_PATH/

################################################################################
# COPY REMAINING GIT REPO CONTENTS TO THE IMAGE
#
# USER $USER
COPY --chown=$USER:$USER . $HOME/$APP/

################################################################################
# Cause the creation of a volume at /opt/dockside.
#
VOLUME $OPT_PATH

################################################################################
# INITIALISE /opt/dockside/bin
#
# launch.sh will overwrite them on launch;
# but when launching a container within the app,
# the inner container will have its own /opt/dockside, and will expect to access these scripts
# before its own launch.sh runs.
#
USER root
RUN mkdir -p $OPT_PATH/bin && \
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
RUN apt-get clean && rm -rf /var/cache/apt/* && rm -rf /var/lib/apt/lists/*

################################################################################
# LAUNCH
#
ENTRYPOINT ["/entrypoint.sh"]
