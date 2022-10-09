FROM alpine:3.15

# Use Ash shell for 'RUN' commands
SHELL ["/bin/ash", "-c"]

RUN adduser -u 1000 -h /home/dockside -s /bin/ash -D dockside

USER dockside
WORKDIR /home/dockside

USER root

# Install ffi from github for compatibility with linux/arm/v7;
# requires autoconf and libffi-dev
RUN apk update && \
    apk add git nodejs npm ruby ruby-dev gcc g++ make musl-dev openssh-client curl patch tig autoconf libffi-dev && \
    gem install bundle

USER dockside
ENV BUNDLE_PATH=/home/dockside/.gems
ADD --chown=dockside:dockside ./Gemfile ./

# Install Gems and patch pathutil.rb to support Ruby >= 3.0.0
RUN mkdir -p $BUNDLE_PATH && \
    bundle install && \
    curl https://github.com/envygeeks/pathutil/commit/3451a10c362fc867b20c7e471a551b31c40a0246.patch | patch -p1 -f -d $(dirname $(find $BUNDLE_PATH -name pathutil.rb))/.. || true && \
    ln -s ./script/.profile ~/

# Add HTML Language Basics plugin
ADD --chown=dockside:dockside https://open-vsx.org/api/vscode/html/1.62.3/file/vscode.html-1.62.3.vsix /home/dockside/theia-plugins/
ADD --chown=dockside:dockside https://open-vsx.org/api/vscode/scss/1.54.1/file/vscode.scss-1.54.1.vsix /home/dockside/theia-plugins/
ADD --chown=dockside:dockside https://open-vsx.org/api/vscode/shellscript/1.54.1/file/vscode.shellscript-1.54.1.vsix /home/dockside/theia-plugins/
ADD --chown=dockside:dockside https://open-vsx.org/api/vscode/docker/1.54.1/file/vscode.docker-1.54.1.vsix /home/dockside/theia-plugins/
ADD --chown=dockside:dockside https://open-vsx.org/api/vscode/json/1.54.1/file/vscode.json-1.54.1.vsix /home/dockside/theia-plugins/

# Add rest of repo
ADD --chown=dockside:dockside ./ ./

ENTRYPOINT [ "/bin/sh", "-c", "/home/dockside/script/server --incremental" ]
