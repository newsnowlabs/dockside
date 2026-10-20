#!/bin/sh
# Starts `jekyll serve` for the site in /home/dockside/app, as the dockside user. Jekyll rebuilds
# the site when a file is saved, and its live-reload server, on port 35729, reloads the open page.
# The site's head include reaches that server through the profile's `ws` router.
set -eu

cd /home/dockside/app
exec setpriv --reuid=dockside --regid=dockside --init-groups \
  env HOME=/home/dockside bundle exec jekyll serve --livereload --host 0.0.0.0 --port 4000
