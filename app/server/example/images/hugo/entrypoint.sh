#!/bin/sh
# Starts `hugo server` for the site in /home/dockside/app, as the dockside user.
#
# $1 is optional: the address the site is served at, such as https://www-blog.example.com. A
# Dockside profile passes it with "command": ["https://www-{container.hostname}"]. Given it, Hugo
# uses it as the site's base URL, without its own port, and its live-reload socket connects to the
# address's own port. Run without it, as with a plain `docker run`, Hugo uses http://localhost:1313.
set -eu

cd /home/dockside/app
if [ -n "${1:-}" ]; then
  exec setpriv --reuid=dockside --regid=dockside --init-groups \
    env HOME=/home/dockside hugo server --bind 0.0.0.0 --port 1313 \
      --baseURL "${1%/}/" --appendPort=false --liveReloadPort 443
fi
exec setpriv --reuid=dockside --regid=dockside --init-groups \
  env HOME=/home/dockside hugo server --bind 0.0.0.0 --port 1313
