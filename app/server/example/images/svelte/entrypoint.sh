#!/bin/sh
# Starts the SvelteKit (Vite) dev server for the app in /home/dockside/app, as the dockside user.
#
# $1 is optional: the address the app is served at, such as https://www-blog.example.com. A Dockside
# profile passes it with "command": ["https://www-{container.hostname}"]. Run without it, as
# with a plain `docker run`, the dev server accepts any host name.
set -eu

if [ -n "${1:-}" ]; then
  DEVTAINER_HOST=${1#*://}
  DEVTAINER_HOST=${DEVTAINER_HOST%%/*}
  export DEVTAINER_HOST
fi

cd /home/dockside/app
exec setpriv --reuid=dockside --regid=dockside --init-groups \
  env HOME=/home/dockside ./node_modules/.bin/vite dev
