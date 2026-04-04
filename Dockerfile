# syntax=docker/dockerfile:1.3-labs

ARG THEIA_ALPINE_VERSION=3.19
ARG THEIA_NODE_VERSION=22
ARG OPENVSCODE_DEBIAN_VERSION=bookworm-slim
ARG SYSTEM_ALPINE_VERSION=3.19
ARG DOCKSIDE_NODE_VERSION=20
ARG DOCKSIDE_DEBIAN_VERSION=bookworm-slim

################################################################################
# SET UP 'BASE' BUILD ENVIRONMENT
#
# (/tmp/dockside will be used by other build stages)
FROM alpine:${SYSTEM_ALPINE_VERSION} AS base

ARG OPT_PATH
ARG TARGETPLATFORM
ARG DOCKSIDE_VERSION

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
    THEIA_VERSION="1.66.1"
    THEIA_VERSION_DIR="latest"
    WSTUNNEL_BINARY="https://storage.googleapis.com/dockside/wstunnel/v6.0/wstunnel-v6.0-linux-x64"
    OPENVSCODE_VERSION="1.109.5"
    OPENVSCODE_BINARY="https://github.com/gitpod-io/openvscode-server/releases/download/openvscode-server-v$OPENVSCODE_VERSION/openvscode-server-v$OPENVSCODE_VERSION-linux-x64.tar.gz"
elif [ "${TARGETPLATFORM}" = "linux/arm64" ]; then
    THEIA_VERSION="1.66.1"
    THEIA_VERSION_DIR="latest"
    WSTUNNEL_BINARY="https://storage.googleapis.com/dockside/wstunnel/v6.0/wstunnel-v6.0-linux-arm64"
    OPENVSCODE_VERSION="1.109.5"
    OPENVSCODE_BINARY="https://github.com/gitpod-io/openvscode-server/releases/download/openvscode-server-v$OPENVSCODE_VERSION/openvscode-server-v$OPENVSCODE_VERSION-linux-arm64.tar.gz"
elif [ "${TARGETPLATFORM}" = "linux/arm/v7" ]; then
    THEIA_VERSION="1.35.0"
    THEIA_BUILD_EXTRA_PACKAGES="ripgrep"
    WSTUNNEL_BINARY="https://storage.googleapis.com/dockside/wstunnel/v6.0/wstunnel-v6.0-linux-armv7"
    OPENVSCODE_VERSION="1.109.5"
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
export THEIA_VERSION_DIR="$THEIA_VERSION_DIR"
export THEIA_PATH="$OPT_PATH/ide/theia/theia-$THEIA_VERSION"
export THEIA_BUILD_PATH="/theia"
export THEIA_BUILD_EXTRA_PACKAGES="$THEIA_BUILD_EXTRA_PACKAGES"

export OPENVSCODE_VERSION="$OPENVSCODE_VERSION"
export OPENVSCODE_BINARY="$OPENVSCODE_BINARY"
export OPENVSCODE_BUILD_DEBIAN_EXTRA_PACKAGES="$OPENVSCODE_BUILD_DEBIAN_EXTRA_PACKAGES"

export DOCKSIDE_VERSION="$DOCKSIDE_VERSION"
export DS_PATH=$OPT_PATH/system/$DOCKSIDE_VERSION

echo "Running command with environment:" >&2
echo "- TARGETPLATFORM=\$TARGETPLATFORM" >&2
echo "- WSTUNNEL_BINARY=\$WSTUNNEL_BINARY" >&2
echo "- THEIA_VERSION=\$THEIA_VERSION THEIA_BUILD_PATH=\$THEIA_BUILD_PATH THEIA_PATH=\$THEIA_PATH" >&2
echo "- OPENVSCODE_BINARY=\$OPENVSCODE_BINARY" >&2
_EOE_

cat <<'_EOE_' >/tmp/dockside/theia-exec && chmod 755 /tmp/dockside/theia-exec
#!/bin/bash

[ -d $THEIA_BUILD_PATH ] && cd $THEIA_BUILD_PATH || true

exec "$@"
_EOE_

apk add --no-cache bash
EOF

################################################################################
# BUILD THEIA IDE
#
FROM node:${THEIA_NODE_VERSION}-alpine${THEIA_ALPINE_VERSION} AS theia-build-env

RUN apk add --no-cache bash git

COPY --from=base /tmp/dockside /tmp/dockside
ENV BASH_ENV=/tmp/dockside/bash-env
SHELL ["/bin/bash", "-c"]

RUN apk update && \
    apk add --no-cache make gcc g++ python3 libsecret-dev

# Add build folders for all Theia versions, as $THEIA_VERSION isn't known to this Dockerfile, only to RUN bash scripts
ADD ./ide/theia /tmp/build/ide/theia

RUN <<EOF
mkdir -p $THEIA_BUILD_PATH
cp -a /tmp/build/ide/theia/$THEIA_VERSION_DIR/build/* $THEIA_BUILD_PATH
# If needed, renaming patch files to include versions, as expected by patch-package
cd $THEIA_BUILD_PATH/patches && for p in *.patch; do [[ "$p" =~ $THEIA_VERSION ]] || mv "$p" "$(echo "$p" | sed -r "s/\.patch$/+$THEIA_VERSION.patch/")";  done
EOF

ENV PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=1
ENV PUPPETEER_SKIP_DOWNLOAD=1
ENV NODE_OPTIONS="--max-old-space-size=8192"
ENV YARN_CACHE_FOLDER=/root/.cache/yarn

FROM theia-build-env AS theia-build

# Build Theia
RUN --mount=type=cache,id=yarn-cache,target=/root/.cache,sharing=locked \
    cd $THEIA_BUILD_PATH && \
    yarn config set network-timeout 600000 -g && \
    yarn --frozen-lockfile

# favicon.ico created using Imagemagick with:
# convert favicon.png -define icon:auto-resize=256,64,48,32,16 -flatten -colors 256 -background transparent -channel RGB -negate favicon.ico
RUN if [ "$THEIA_VERSION" = "1.35.0" ]; then DST="lib/"; else DST="lib/frontend/"; fi && \
    cp -a /tmp/build/ide/theia/$THEIA_VERSION_DIR/build/images/favicon.ico $THEIA_BUILD_PATH/$DST

# Default diagnostics entrypoint for this stage
# (and the next, which inherits it)
# Matches $THEIA_BUILD_PATH
ENTRYPOINT ["/tmp/dockside/theia-exec", "node", "./lib/backend/main.js", "./", "--hostname", "0.0.0.0", "--port", "3131"]

################################################################################
# CLEAN THEIA IDE
#
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
    rm -rf patches images && \
    rm -rf node_modules/puppeteer/.local-chromium

################################################################################
# BUILD THEIA IDE BUNDLE
#
# Patch all binaries and dynamic libraries for full portability.
FROM theia-clean AS theia-ide

ARG OPT_PATH

# The version of rg installed by the Theia build on linux/arm/v7
# depends on libs that are not available on Alpine on this platform.
# Workaround this by overwriting it with Alpine's own rg.
# ARG TARGETPLATFORM
RUN if [ "$TARGETPLATFORM" = "linux/arm/v7" ]; then \
      apk add --no-cache ripgrep; \
      cp $(which rg) $(find $THEIA_BUILD_PATH -name rg); \
    fi

RUN apk add --no-cache file patchelf coreutils findutils

ADD build/development/make-bundelf-bundle.sh /tmp

RUN export \
        BUNDELF_BINARIES="node" \
        BUNDELF_DYNAMIC_PATHS="$THEIA_BUILD_PATH" \
        BUNDELF_CODE_PATH="$THEIA_PATH" \
        BUNDELF_LIBPATH_TYPE="relative" \
        BUNDELF_MERGE_BINDIRS="1" && \
    /tmp/make-bundelf-bundle.sh --bundle && \
    cd $THEIA_PATH/bin && \
    cp -a /tmp/build/ide/theia/$THEIA_VERSION_DIR/bin/* $THEIA_PATH/bin && \
    cd $THEIA_PATH/.. && \
    ln -sf theia-$THEIA_VERSION latest

# Default diagnostics entrypoint for this stage (uses relocatable node and Theia, loses BASH_ENV build environment)
WORKDIR $OPT_PATH/ide/theia/latest/theia
ENTRYPOINT ["../bin/node", "./lib/backend/main.js", "/root", "--hostname", "0.0.0.0", "--port", "3131"]

################################################################################
# INSTALL BUILT-IN THEIA IDE VSIX PLUGINS
#
FROM theia-ide AS theia-ide-plugins

# Download 'built-in' VSIX plugins
# Formats:
# - <publisher>.<name>       : download metadata to determine latest version URL, then download plugin
# - <publisher>.<name>-<ver> : download plugin directly from implied URL (faster and fully cacheable)

# All small plugins
ARG VSIX_PLUGINS="vscode.bat@1.95.3 vscode.clojure@1.95.3 vscode.coffeescript@1.95.3 vscode.configuration-editing@1.95.3 vscode.cpp@1.95.3 vscode.csharp@1.95.3 vscode.css@1.95.3 vscode.dart@1.95.3 vscode.debug-auto-launch@1.95.3 vscode.debug-server-ready@1.95.3 vscode.diff@1.95.3 vscode.docker@1.95.3 vscode.emmet@1.95.3 vscode.fsharp@1.95.3 vscode.git@1.95.3 vscode.git-base@1.95.3 vscode.github@1.95.3 vscode.github-authentication@1.95.3 vscode.go@1.95.3 vscode.groovy@1.95.3 vscode.grunt@1.95.3 vscode.gulp@1.95.3 vscode.handlebars@1.95.3 vscode.hlsl@1.95.3 vscode.html@1.95.3 vscode.ini@1.95.3 vscode.ipynb@1.95.3 vscode.jake@1.95.3 vscode.java@1.95.3 vscode.javascript@1.95.3 vscode.json@1.95.3 vscode.julia@1.95.3 vscode.latex@1.95.3 vscode.less@1.95.3 vscode.log@1.95.3 vscode.lua@1.95.3 vscode.make@1.95.3 vscode.markdown@1.95.3 vscode.markdown-math@1.95.3 vscode.media-preview@1.95.3 vscode.merge-conflict@1.95.3 vscode.builtin-notebook-renderers@1.95.3 vscode.npm@1.95.3 vscode.objective-c@1.95.3 vscode.perl@1.95.3 vscode.php@1.95.3 vscode.powershell@1.95.3 vscode.python@1.95.3 vscode.pug@1.95.3 vscode.r@1.95.3 vscode.razor@1.95.3 vscode.references-view@1.95.3 vscode.restructuredtext@1.95.3 vscode.ruby@1.95.3 vscode.rust@1.95.3 vscode.scss@1.95.3 vscode.search-result@1.95.3 vscode.shaderlab@1.95.3 vscode.shellscript@1.95.3 vscode.simple-browser@1.95.3 vscode.sql@1.95.3 vscode.swift@1.95.3 vscode.theme-abyss@1.95.3 vscode.theme-defaults@1.95.3 vscode.theme-kimbie-dark@1.95.3 vscode.theme-monokai@1.95.3 vscode.theme-monokai-dimmed@1.95.3 vscode.theme-quietlight@1.95.3 vscode.theme-red@1.95.3 vscode.vscode-theme-seti@1.95.3 vscode.theme-solarized-dark@1.95.3 vscode.theme-solarized-light@1.95.3 vscode.theme-tomorrow-night-blue@1.95.3 vscode.tunnel-forwarding@1.95.3 vscode.typescript@1.95.3 vscode.vb@1.95.3 vscode.xml@1.95.3 vscode.yaml@1.95.3 ms-vscode.js-debug-companion ms-vscode.js-debug github.vscode-pull-request-github openai.chatgpt Anthropic.claude-code"

# Large plugins: enable if needed
# ARG VSIX_PLUGINS_LARGE="vscode.css-language-features@1.95.3 vscode.html-language-features@1.95.3 vscode.json-language-features@1.95.3 vscode.markdown-language-features@1.95.3 vscode.php-language-features@1.95.3 vscode.typescript-language-features@1.95.3"

# Cache mount holds downloaded .vsix files across builds
RUN apk add --no-cache curl libarchive-tools jq && \
    mkdir -p "$THEIA_PATH/theia/plugins"

RUN --mount=type=cache,id=openvsx,target=/cache/openvsx,sharing=locked <<_EOE_
set -euo pipefail

for id in ${VSIX_PLUGINS:-} ${VSIX_PLUGINS_LARGE:-}
do
    pub="${id%%.*}"        # publisher (split at first '.')
    rest="${id#*.}"        # "name" or "name-<version>"
    name="$rest"
    ver=""

    # If there is an '@' followed by a digit, treat that as the start of <version>.
    # This copes with names containing hyphens and versions like 1.2.3 or 1.2.3-beta.1
    # Parse name, ver; generate url.
    case "$rest" in
      *@[0-9]*)
        base="${rest%@[0-9]*}"     # shortest suffix '@[0-9]*' removed → leaves the name
        ver="${rest#${base}@}"     # everything after that '@' is the version
        name="$base"
        url="https://open-vsx.org/api/${pub}/${name}/${ver}/file/${pub}.${name}-${ver}.vsix"
        printf 'Parsed %s as pub=%s name=%s ver=%s url=%s ...\n' "$id" "$pub" "$name" "$ver" "$url" >&2
        ;;
    esac

    # If no ver parsed, obtain ver and url from metadata.
    if [ -z "$ver" ]; then
      echo "Downloading $id metadata from https://open-vsx.org/api/$pub/$name ..." >&2
      meta="$(curl -fsSL "https://open-vsx.org/api/$pub/$name")" # or /api/$pub/$name/latest
      url="$(printf '%s' "$meta" | jq -r '.files.download')"     # direct VSIX URL
      ver="$(printf '%s' "$meta" | jq -r '.version')"            # latest version string
      printf 'Retrieved %s as pub=%s name=%s ver=%s url=%s ...\n' "$id" "$pub" "$name" "$ver" "$url" >&2
    fi

    # Look for the cached vsix file ...
    vsix="/cache/openvsx/$pub/$name/$ver.vsix"
    if [ ! -s "$vsix" ]; then
      mkdir -p "$(dirname "$vsix")"
      echo "Downloading $id from $url to $vsix ..." >&2
      curl --fail --silent --show-error --location --retry 3 --max-time 20 "$url" -o "$vsix.tmp"
      # Only save tmp copy if download successful
      mv "$vsix.tmp" "$vsix"
    else
      echo "Using cached $id from $url @ $vsix ..." >&2
    fi

    dest="$THEIA_PATH/theia/plugins/$pub.$name-$ver"
    mkdir -p "$dest"
    echo "Untarring $id @ $vsix to $dest ..." >&2
    bsdtar -xf "$vsix" -C "$dest"
done
_EOE_

################################################################################
# BUILD DOCKSIDE 'SYSTEM' BINARY BUNDLE
#
# Patch all binaries and dynamic libraries for full portability.
FROM base AS system

ARG DOCKSIDE_VERSION

# The BASH_ENV script will be executed prior to running all other RUN commands from here-on.
ENV BASH_ENV=/tmp/dockside/bash-env
SHELL ["/bin/bash", "-c"]

RUN apk add --no-cache make gcc g++ python3 libsecret-dev s6 curl file patchelf bash dropbear jq git openssh-client-default github-cli

ADD build/development/make-bundelf-bundle.sh /tmp

RUN export \
        BUNDELF_BINARIES="bash busybox s6-svscan curl dropbear dropbearkey jq /usr/libexec/git-core/git /usr/libexec/git-core/git-remote-http ssh ssh-add ssh-agent ssh-keyscan gh" \
        BUNDELF_CODE_PATH="$DS_PATH" \
        BUNDELF_LIBPATH_TYPE="relative" \
        BUNDELF_MERGE_BINDIRS="1" && \
    env | sort && \
    /tmp/make-bundelf-bundle.sh --bundle

RUN cd $DS_PATH/bin && \
    ln -sf busybox sh && \
    ln -sf busybox su && \
    ln -sf busybox pgrep && \
    ln -sf git git-clone && \
    ln -sf git-remote-http git-remote-https && \
    cp -a /etc/ssl/certs $DS_PATH/ && \
    curl -SsL -o wstunnel $WSTUNNEL_BINARY && chmod 755 wstunnel

# Create a wrapper for `gh` that sets SSL_CERT_FILE as needed
# so providing fully working terminal access to gh
RUN cd $DS_PATH/bin && \
    mv gh gh.orig && \
    echo -e "#!$DS_PATH/bin/sh\nexport SSL_CERT_FILE=$DS_PATH/certs/ca-certificates.crt\nexec gh.orig \"\$@\"\n" >gh && \
    chmod 755 gh

# Create system/latest symlink pointing to the versioned directory
RUN cd $DS_PATH/.. && ln -sf $DOCKSIDE_VERSION latest

################################################################################
# BUILD OPENVSCODE IDE BINARY BUNDLE
#
# Patch all binaries and dynamic libraries for full portability.
FROM debian:$OPENVSCODE_DEBIAN_VERSION AS openvscode-ide

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
    cp -a /tmp/bin $OPENVSCODE_VERSION/ && \
    cd latest/openvscode/bin/remote-cli && ln -s openvscode-server code

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
# DOCKSIDE REPO CLEAN BUILD
#
FROM alpine/git AS dockside-repo

COPY . /git/dockside
RUN cd /git/dockside && \
    current=$(git rev-parse --abbrev-ref HEAD) && \
    remote=$(git remote get-url origin) && \
    git remote remove origin && \
    git remote add origin "$remote" && \
    git branch | grep -v '^\* ' | xargs -r git branch -D && \
    git gc

################################################################################
# MAIN DOCKSIDE BUILD
#
FROM node:$DOCKSIDE_NODE_VERSION-$DOCKSIDE_DEBIAN_VERSION AS dockside-1

ENV DEBIAN_FRONTEND=noninteractive

ARG OPT_PATH
ARG USER=dockside
ARG APP=dockside
ARG HOME=/home/dockside

# Use bash shell
SHELL ["/bin/bash", "-c"]

# ---------------------------
# DOCKER INSTALL DEPENDENCIES
# (See https://docs.docker.com/install/linux/docker-ce/debian/)
#
COPY build/development/install-dev-dependencies.sh /tmp/install-dev-dependencies.sh
RUN apt-get update && \
    apt-get -y upgrade && \
    apt-get -y --no-install-recommends --no-install-suggests install \
        apt-transport-https ca-certificates \
        curl \
        gnupg2 && \
    curl -fsSL https://download.docker.com/linux/debian/gpg | apt-key add - && \
    echo "deb https://download.docker.com/linux/debian $(cat /etc/os-release | grep VERSION_CODENAME | cut -d '=' -f2) stable" >/etc/apt/sources.list.d/docker.list && \
    apt-get update && \
    /tmp/install-dev-dependencies.sh && \
    apt-get -y --no-install-recommends --no-install-suggests install \
        docker-ce docker-ce-cli docker-buildx-plugin containerd.io gcc-

# -----------------------------------------
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

# ----------------
# DEHYDRATED SETUP
#
USER $USER
COPY --chown=$USER:$USER dehydrated $HOME/$APP/dehydrated/

# ------------------
# VUE CLIENT INSTALL
#
COPY --chown=$USER:$USER app/client $HOME/$APP/app/client/
WORKDIR $HOME/$APP/app/client
RUN npm install && npm run build && npm cache clean --force
RUN rm -rf $HOME/.npm

# --------------
# MKDOCS INSTALL
#
COPY --chown=$USER:$USER app/server/assets $HOME/$APP/app/server/assets/
COPY --chown=$USER:$USER docs $HOME/$APP/docs/
COPY --chown=$USER:$USER mkdocs.yml $HOME/$APP/
WORKDIR $HOME/$APP
RUN python3 -m venv ~/mkdocs && ~/mkdocs/bin/pip3 install --no-warn-script-location mkdocs mkdocs-material==8.4.4 && ~/mkdocs/bin/mkdocs build && rm -rf ~/.cache/pip

FROM dockside-1 AS dockside
LABEL maintainer="Struan Bartlett <struan.bartlett@NewsNow.co.uk>"

ENV DEBIAN_FRONTEND=noninteractive

ARG OPT_PATH
ARG THEIA_PATH=$OPT_PATH/ide/theia
ARG VSCODE_PATH=$OPT_PATH/ide/openvscode
ARG DS_PATH=$OPT_PATH/system
ARG USER=dockside
ARG APP=dockside
ARG HOME=/home/dockside

# ------------------
# BUNDLE INTEGRATION
#
COPY --from=base /tmp/dockside /tmp/dockside
COPY --from=system $DS_PATH $DS_PATH/
COPY --from=theia-ide-plugins $THEIA_PATH $THEIA_PATH/
COPY --from=openvscode-ide $VSCODE_PATH $VSCODE_PATH/

# ---------------------------------------------
# COPY REMAINING GIT REPO CONTENTS TO THE IMAGE
#
COPY --from=dockside-repo --chown=$USER:$USER /git/dockside $HOME/$APP/

# -----------------------------
# Last things for dockside user
USER $USER
WORKDIR $HOME
RUN cp -a ~/$APP/build/development/dot-theia .vscode && \
    cd ~ && ln -s .vscode .theia && cd - && \
    ln -s ~/$APP/build/development/perltidyrc ~/.perltidyrc && \
    ln -s ~/$APP/build/development/vetur.config.js ~/

# -------------------------
# Last things for root user
USER root
RUN . /tmp/dockside/bash-env && \
    mkdir -p $OPT_PATH/bin $OPT_PATH/host && \
    cp -a $HOME/$APP/app/scripts/container/launch.sh $OPT_PATH/bin/ && \
    ln -sfr $OPT_PATH/bin/launch.sh $OPT_PATH/launch.sh && \
    ln -sf $HOME/$APP/app/scripts/entrypoint.sh /entrypoint.sh && \
    ln -sf $HOME/$APP/app/server/bin/password-wrapper /usr/local/bin/password && \
    ln -sf $HOME/$APP/app/server/bin/upgrade /usr/local/bin/upgrade && \
    chown -R root:root $OPT_PATH/bin/ && \
    # For backwards compatibility with legacy config.json /home/newsnow paths
    ln -sf $HOME /home/newsnow && \
    apt-get clean && rm -rf /var/cache/apt/* && rm -rf /var/lib/apt/lists/* && rm -rf /tmp/*

# ------------------------
# DEVELOPMENT DEPENDENCIES
#
RUN apt-get update && \
    apt-get -y --no-install-recommends --no-install-suggests install \
        libfile-find-rule-perl libperl-languageserver-perl \
        git tig perltidy \
        shellcheck \
        procps vim less curl locales && \
    apt-get clean && rm -rf /var/cache/apt/* && rm -rf /var/lib/apt/lists/* && rm -rf /tmp/*

# ----------
# GCLOUD SDK
# - https://cloud.google.com/sdk/docs/quickstart-debian-ubuntu
#
# RUN echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] http://packages.cloud.google.com/apt cloud-sdk main" | tee -a /etc/apt/sources.list.d/google-cloud-sdk.list && curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key --keyring /usr/share/keyrings/cloud.google.gpg  add - && apt-get update && apt-get -y install google-cloud-sdk

# --------------------------------
# INSTALL DEVELOPMENT VSIX PLUGINS
#
# (disabled as there are currently no VSIX extensions needing to be embedded in the image)
# COPY --from=vsix-plugins --chown=$USER:$USER /root/theia-plugins $HOME/theia-plugins/

# -----------------------------------------------
# Relocate /opt/dockside content to /opt/dockside.img so the entrypoint
# can copy it into the named volume at /opt/dockside on container start.
# This enables safe in-place upgrades: launch a new container against the
# same named volume and  it will be brought up to date automatically.
RUN mv $OPT_PATH $OPT_PATH.img && mkdir -p $OPT_PATH

# -----------------------------------------------
# Cause the creation of a volume at /opt/dockside
#
VOLUME $OPT_PATH

# ------------------------------------------------------------
# Create a separate volume for host-specific data to be shared
# read-only with devtainers
VOLUME $OPT_PATH/host

################################################################################
# LAUNCH
#
ENTRYPOINT ["/entrypoint.sh"]
