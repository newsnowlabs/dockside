# Hugo example image

A small [Hugo](https://gohugo.io) site, with a home page, a posts section and three plain
templates, served by `hugo server`. A devtainer launched from it shows the site straight away, and
when a file is saved in the IDE Hugo rebuilds the site and reloads the open page.

- **Image:** `ghcr.io/newsnowlabs/dockside/example/images/hugo`
- **Port:** 1313 (the site and Hugo's live-reload socket)
- **Site:** `/home/dockside/app`, owned by the `dockside` user, inside the home folder that the IDE opens. Try editing `content/_index.md`, or add a post in `content/posts/`.
- **Profile:** `240-hugo` in `app/server/example/config/profiles/`

This is an unofficial example for showing Dockside, not a production deployment, and is not
affiliated with or endorsed by the Hugo project. The image contains the Hugo release binary
(Apache-2.0), downloaded at build time and checked against its published checksums; the site's own
files are part of this repository.

## Build

    ./build.sh               # build for this machine
    ./build.sh --push        # build, then push (docker login ghcr.io first)
    ./build.sh --multiarch   # build for amd64 and arm64 and push

The Hugo version is the `HUGO_VERSION` argument in the `Dockerfile`.

## Try it without Dockside

    docker run --rm -p 1313:1313 ghcr.io/newsnowlabs/dockside/example/images/hugo

and open http://localhost:1313/.

## How the address is handled

Behind Dockside's proxy the site is served over HTTPS on port 443, from a host name the image
cannot know when it is built. The profile passes it to the entrypoint as an argument,
`"command": ["https://www-{container.hostname}"]`, which the entrypoint gives to `hugo server` as
the base URL, with `--appendPort=false` so that Hugo does not add its own port to it, and
`--liveReloadPort 443` so that the page's live-reload socket connects to the proxy's port.
