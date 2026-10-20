# React (Next.js) example image

A small React app, built with the [Next.js](https://nextjs.org) framework, made with `create-next-app` and
served by its dev server, with its dependencies installed. A devtainer launched from it shows the
app straight away, and an edit saved in the IDE appears in the page without a reload.

- **Image:** `ghcr.io/newsnowlabs/dockside/example/images/react-nextjs`
- **Port:** 3000 (the Next.js dev server, including its live-update socket)
- **App:** `/home/dockside/app`, owned by the `dockside` user, inside the home folder that the IDE opens. Try editing `app/page.tsx`.
- **Profile:** `200-react-nextjs` in `app/server/example/config/profiles/`

This is an unofficial example for showing Dockside, not a production deployment, and is not
affiliated with or endorsed by Vercel, Meta or the Next.js and React projects. The starter app's
files are from create-next-app, which is MIT-licensed.

## Build

    ./build.sh               # build for this machine
    ./build.sh --push        # build, then push (docker login ghcr.io first)
    ./build.sh --multiarch   # build for amd64 and arm64 and push

## Try it without Dockside

    docker run --rm -p 3000:3000 ghcr.io/newsnowlabs/dockside/example/images/react-nextjs

and open http://localhost:3000/.

## How the address is handled

Behind Dockside's proxy the page is served from a host name the image cannot know when it is
built. The profile passes it to the entrypoint as an argument,
`"command": ["https://www-{container.hostname}"]`. The entrypoint gives its host name to
`next.config.ts`, which lists it in `allowedDevOrigins`, so the dev server answers requests for its
assets from that host. Without the argument, the dev server accepts only localhost.
