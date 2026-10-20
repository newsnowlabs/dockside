# Vue 3 (Nuxt) example image

A small [Nuxt](https://nuxt.com) app (a Vue 3 framework), made with `create-nuxt` (the `minimal`
template) and served by its dev server, with its dependencies installed. A devtainer launched from it
shows the app straight away, and an edit saved in the IDE appears in the page without a reload.

- **Image:** `ghcr.io/newsnowlabs/dockside/example/images/vue3-nuxt`
- **Port:** 3000 (the Nuxt dev server, including its live-update socket)
- **App:** `/home/dockside/app`, owned by the `dockside` user, inside the home folder that the IDE opens. Try editing `app/app.vue`.
- **Profile:** `215-vue3-nuxt` in `app/server/example/config/profiles/`

This is an unofficial example for showing Dockside, not a production deployment, and is not
affiliated with or endorsed by the Nuxt, Vue or Vite projects. The starter app's files are from
create-nuxt, which is MIT-licensed.

## Build

    ./build.sh               # build for this machine
    ./build.sh --push        # build, then push (docker login ghcr.io first)
    ./build.sh --multiarch   # build for amd64 and arm64 and push

## Try it without Dockside

    docker run --rm -p 3000:3000 ghcr.io/newsnowlabs/dockside/example/images/vue3-nuxt

and open http://localhost:3000/.

## How the address is handled

Behind Dockside's proxy the page is served over HTTPS on port 443, from a host name the image
cannot know when it is built. The profile passes it to the entrypoint as an argument,
`"command": ["https://www-{container.hostname}"]`. The entrypoint gives its host name to
`nuxt.config.ts`, which lists it in Vite's `allowedHosts`. Nuxt serves its live-update socket on the
page's own port, at `/_nuxt/`, so nothing more is needed. Without the argument, any host is accepted.

## Start-up time

Nuxt prepares and builds the app each time the devtainer starts, which takes about 25 seconds. A
page requested before that shows the proxy's 502 error; reload once the server is up.
