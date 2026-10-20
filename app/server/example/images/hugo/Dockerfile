# A Hugo site, served by `hugo server` so that an edit saved in the IDE shows in the browser.
# See README.md.
FROM debian:stable-slim

ARG TARGETARCH
ARG HUGO_VERSION=0.168.0

LABEL org.opencontainers.image.source="https://github.com/newsnowlabs/dockside" \
      org.opencontainers.image.title="Dockside example: Hugo site" \
      org.opencontainers.image.description="A Hugo site, with its dev server, for launching in Dockside."

# sudo, git and curl are what a developer expects in a devtainer's terminal (and Hugo uses git for
# page dates and modules). Hugo's release is checked against the checksums published with it. The
# dockside user exists before Dockside starts the devtainer's IDE, so the site's files can be
# owned by it.
RUN apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends sudo git curl ca-certificates libstdc++6 \
 && cd /tmp \
 && archive="hugo_extended_${HUGO_VERSION}_linux-${TARGETARCH}.tar.gz" \
 && curl -fsSLO "https://github.com/gohugoio/hugo/releases/download/v${HUGO_VERSION}/${archive}" \
 && curl -fsSLO "https://github.com/gohugoio/hugo/releases/download/v${HUGO_VERSION}/hugo_${HUGO_VERSION}_checksums.txt" \
 && grep " ${archive}\$" "hugo_${HUGO_VERSION}_checksums.txt" | sha256sum -c - \
 && tar -xzf "${archive}" -C /usr/local/bin hugo \
 && rm -f /tmp/hugo_* \
 && rm -rf /var/lib/apt/lists/* \
 && useradd -m -s /bin/bash dockside \
 && install -d -o dockside -g dockside /home/dockside/app

WORKDIR /home/dockside/app
COPY --chown=dockside:dockside app/ ./

# The entrypoint runs as root and starts the server as the dockside user, so that Dockside's
# launch script, which needs root, can run in the container too.
COPY entrypoint.sh /usr/local/bin/dockside-example-entrypoint
# Documents the port the server listens on. Dockside does not need it: it reaches the port that
# the profile's router names, over the devtainer's network. It publishes nothing on the host.
EXPOSE 1313
ENTRYPOINT ["/usr/local/bin/dockside-example-entrypoint"]
