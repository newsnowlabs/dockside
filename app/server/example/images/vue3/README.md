# Vue 3 example image

A small Vue 3 app, made with [create-vue](https://github.com/vuejs/create-vue) and served by its
[Vite](https://vite.dev) dev server, with its dependencies installed. A devtainer launched from it
shows the app straight away, and an edit saved in the IDE appears in the page without a reload.

- **Image:** `ghcr.io/newsnowlabs/dockside/example/images/vue3`
- **Port:** 5173 (the Vite dev server, including its live-update socket)
- **App:** `/home/dockside/app`, owned by the `dockside` user, inside the home folder that the IDE opens. Try editing `src/App.vue`.
- **Profile:** `210-vue` in `app/server/example/config/profiles/`

This is an unofficial example for showing Dockside, not a production deployment, and is not
affiliated with or endorsed by the Vue or Vite projects. The starter app's files are from
create-vue, which is MIT-licensed.

## Build

    ./build.sh               # build for this machine
    ./build.sh --push        # build, then push (docker login ghcr.io first)
    ./build.sh --multiarch   # build for amd64 and arm64 and push

## Try it without Dockside

    docker run --rm -p 5173:5173 ghcr.io/newsnowlabs/dockside/example/images/vue3

and open http://localhost:5173/.

## How the address is handled

Behind Dockside's proxy the page is served over HTTPS on port 443, from a host name the image
cannot know when it is built. The profile passes it to the entrypoint as an argument,
`"command": ["https://www-{container.hostname}"]`. The entrypoint gives its host name to Vite,
which accepts only that host and sends its live-update socket to port 443. Without the argument,
Vite accepts any host and uses its own port.
