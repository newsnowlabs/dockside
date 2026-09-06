# Demo image for docs/extensions/lifecycle-hooks.md's multi-repo example profiles
# (05-image-embedded-multi-repo-hook.json, 06-image-embedded-multi-repo-entrypoint.json).
#
# Bakes in two toy "repos" (alpha, beta), each already checked out from its own local bare
# "upstream" remote - so the example profiles' branch-switch logic exercises real
# `git fetch`/`switch` against a real origin, with zero network dependency (no GitHub account,
# token, or connectivity needed to build or run this image). Each repo has two branches
# ('main', 'feature-x') whose only difference is the text in served-content.txt - so switching
# branch is visibly observable via `dockside check-url` against the port it's served on.
#
# Build (from this directory): docker build -t dockside-example-multi-repo:latest .
# Both example profiles reference that exact tag - build it first, or their launch fails with
# "no such image", same as any other bring-your-own-image profile.

FROM debian:latest

RUN apt-get update -qq \
 && apt-get install -y -qq git python3 sudo \
 && rm -rf /var/lib/apt/lists/* \
 && useradd -m -s /bin/bash dockside \
 && echo 'dockside ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/dockside \
 && mkdir -p /opt/upstream \
 && chown dockside:dockside /opt/upstream

USER dockside
WORKDIR /home/dockside

# Build both toy repos: a bare "upstream" at /opt/upstream/<name>.git with two branches, plus a
# working clone at /home/dockside/<name> checked out on main, with 'origin' pointing at the
# bare repo via a plain filesystem path (git's file:// transport - no daemon/server needed).
RUN set -e; \
    git config --global user.email "demo@example.invalid"; \
    git config --global user.name "Dockside example"; \
    git config --global init.defaultBranch main; \
    for name in alpha beta; do \
       git init --bare -q "/opt/upstream/$name.git"; \
       tmp="$(mktemp -d)"; \
       git init -q "$tmp"; \
       echo "$name @ main" > "$tmp/served-content.txt"; \
       git -C "$tmp" add -A; \
       git -C "$tmp" commit -q -m "$name: content on main"; \
       git -C "$tmp" checkout -qb feature-x; \
       echo "$name @ feature-x" > "$tmp/served-content.txt"; \
       git -C "$tmp" commit -q -am "$name: content on feature-x"; \
       git -C "$tmp" checkout -q main; \
       git -C "$tmp" remote add origin "/opt/upstream/$name.git"; \
       git -C "$tmp" push -q origin main feature-x; \
       git clone -q "/opt/upstream/$name.git" "/home/dockside/$name"; \
       rm -rf "$tmp"; \
    done

COPY --chown=dockside:dockside multi-repo-switch-and-serve.sh /opt/dockside-examples/multi-repo/multi-repo-switch-and-serve.sh
RUN chmod +x /opt/dockside-examples/multi-repo/multi-repo-switch-and-serve.sh
