# Jekyll example image

A small [Jekyll](https://jekyllrb.com) site, made with `jekyll new` (the Minima theme) and served
by `jekyll serve`, with its gems installed. A devtainer launched from it shows the site straight
away, and when a file is saved in the IDE Jekyll rebuilds the site and reloads the open page.

- **Image:** `ghcr.io/newsnowlabs/dockside/example/images/jekyll`
- **Ports:** 4000 (the site) and 35729 (Jekyll's live-reload server)
- **Site:** `/home/dockside/app`, owned by the `dockside` user, inside the home folder that the IDE opens. Try editing `_posts/2025-01-01-welcome-to-jekyll.markdown` or `index.markdown`.
- **Profile:** `220-jekyll` in `app/server/example/config/profiles/`, with a `www` router for the
  site and a `ws` router for the live-reload server

This is an unofficial example for showing Dockside, not a production deployment, and is not
affiliated with or endorsed by the Jekyll project. The starter site's files are from `jekyll new`,
which is MIT-licensed.

## Build

    ./build.sh               # build for this machine
    ./build.sh --push        # build, then push (docker login ghcr.io first)
    ./build.sh --multiarch   # build for amd64 and arm64 and push

## Try it without Dockside

    docker run --rm -p 4000:4000 -p 35729:35729 ghcr.io/newsnowlabs/dockside/example/images/jekyll

and open http://localhost:4000/.

## Live reload

Jekyll's `--livereload` adds a script to each page that connects to port 35729 of the page's own
host name. Dockside's proxy publishes only the port a router names, on HTTPS, so that connection
cannot reach the devtainer. The image therefore serves the live-reload server through a second
router, `ws`, whose address is `ws-<name>.<domain>` on the proxy's own port, and loads the
live-reload client from there:

- `app/_includes/head.html` is the site's head include, and loads the live-reload client. The script uses the
  `ws` address when the page's host name begins `www-`, and port 35729 of the page's host
  otherwise, which is where `docker run -p 35729:35729` publishes it.
- The tag in that file is written `<HEAD>`, in upper case. Jekyll adds its own script only after
  a lower-case `<head>`, so this keeps the page from loading the client twice, once from an
  address that does not work.

The `ws` router's access list is the profile's own, so a viewer who is shown the site but not
given access to `ws` sees it without live reload.

## The address

Jekyll's `serve` command sets the site's `url` to its own address (here `http://0.0.0.0:4000`)
while in development, so absolute links, such as the feed link in the page head, name that
address and not the devtainer's. The site's pages and assets use relative links, so they are
unaffected. The profile passes no address to the image.
