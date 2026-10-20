# A React app, built with the Next.js framework by create-next-app, served by its dev server so
# that an edit saved in the IDE shows in the browser. See README.md.
FROM node:24-slim

LABEL org.opencontainers.image.source="https://github.com/newsnowlabs/dockside" \
      org.opencontainers.image.title="Dockside example: React app (Next.js)" \
      org.opencontainers.image.description="A React app, built with Next.js, with its dev server, for launching in Dockside."

# sudo and git are what a developer expects in a devtainer's terminal. The dockside user exists
# before Dockside starts the devtainer's IDE, so the app's files can be owned by it.
RUN apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends sudo git ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && useradd -m -s /bin/bash dockside \
 && install -d -o dockside -g dockside /home/dockside/app

ENV NEXT_TELEMETRY_DISABLED=1

WORKDIR /home/dockside/app

COPY --chown=dockside:dockside app/package.json app/package-lock.json ./
USER dockside
RUN npm ci && npm cache clean --force
COPY --chown=dockside:dockside app/ ./

# The entrypoint runs as root and starts the dev server as the dockside user, so that Dockside's
# launch script, which needs root, can run in the container too.
USER root
COPY entrypoint.sh /usr/local/bin/dockside-example-entrypoint
# Documents the port the server listens on. Dockside does not need it: it reaches the port that
# the profile's router names, over the devtainer's network. It publishes nothing on the host.
EXPOSE 3000
ENTRYPOINT ["/usr/local/bin/dockside-example-entrypoint"]
