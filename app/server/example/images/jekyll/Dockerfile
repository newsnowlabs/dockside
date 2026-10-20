# A Jekyll site, made with `jekyll new`, served by `jekyll serve` so that an edit saved in the IDE
# rebuilds the site. See README.md.
FROM ruby:3.4-slim

LABEL org.opencontainers.image.source="https://github.com/newsnowlabs/dockside" \
      org.opencontainers.image.title="Dockside example: Jekyll site" \
      org.opencontainers.image.description="A Jekyll site, served by jekyll serve, for launching in Dockside."

# sudo and git are what a developer expects in a devtainer's terminal. The dockside user exists
# before Dockside starts the devtainer's IDE, so the site's files can be owned by it.
RUN apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends sudo git ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && useradd -m -s /bin/bash dockside \
 && install -d -o dockside -g dockside /home/dockside/app

WORKDIR /home/dockside/app

# The gems are installed from the lock file, with the compiler present only while they build.
COPY --chown=dockside:dockside app/Gemfile app/Gemfile.lock ./
RUN apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends build-essential \
 && su dockside -c 'BUNDLE_FROZEN=true bundle install' \
 && apt-get purge -y -qq build-essential && apt-get autoremove -y -qq \
 && rm -rf /var/lib/apt/lists/*
COPY --chown=dockside:dockside app/ ./

# The entrypoint runs as root and starts the server as the dockside user, so that Dockside's
# launch script, which needs root, can run in the container too.
COPY entrypoint.sh /usr/local/bin/dockside-example-entrypoint
# Documents the ports the site (4000) and its live-reload server (35729) listen on. Dockside does
# not need them: it reaches the ports that the profile's routers name, over the devtainer's network.
# They publish nothing on the host.
EXPOSE 4000 35729
ENTRYPOINT ["/usr/local/bin/dockside-example-entrypoint"]
