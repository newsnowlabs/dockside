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

# Add rest of repo
ADD --chown=dockside:dockside ./ ./

# Uncomment to enable package upgrades during image build;
# otherwise inbuilt node_modules/* will be used.
# RUN npm install && npm upgrade && npm cache clean --force

ENTRYPOINT [ "/bin/sh", "-c", "/home/dockside/script/server --incremental" ]
