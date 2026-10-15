# Dockside Web Client

The browser single-page app — Vue 3 + Vuetify 3 + Vuex 4 + Vue Router 4, bundled
with Vite and served by the Dockside server.

## Build / develop

```sh
cd dockside/app/client
npm install        # install dependencies
npm run build      # build dist/ (the server serves dist/assets/ and reads dist/manifest.json)
npm run start      # watch and rebuild on change
```

Lint and build checks also run from the repo root: `./test.sh --only vue`,
`--only eslint`, `--only stylelint`.

## Build outputs

`npm run build` puts every built file - the entry module, lazy-loaded chunks such as
the admin screens, their stylesheets, source maps, fonts - in
`dist/assets/<name>-<hash>.<ext>`, named with a hash of its content. The server serves
them at `/assets/<file>`, before login, cached for a long time.

It also writes `dist/manifest.json`, Vite's build manifest. The server reads it to find
the entry module (the one chunk marked `isEntry`) and that entry's stylesheets, and
writes them into the page as `<script type="module" src="/assets/...">` and
`<link rel="stylesheet" href="/assets/...">`. Lazy-loaded chunks import the entry by the
same hashed name, so the browser loads it once.

The entry must stay under `dist/assets/` with the chunks: the browser resolves the
entry's dynamic `import()` paths relative to its own URL, so its place on disk must
match that URL. See `vite.config.js` for details.

## Layout

- **Entry point — `src/index.js`:** creates the Vuex store (whose modules
  `src/store/index.js` registers) *before* the router, so the route guards can read
  the live current user, and defines the routes behind permission-aware guards.
- **Routes / layouts:** the default container view; `/admin/users`, `/admin/roles`,
  `/admin/profiles` (gated on the `manageUsers` / `manageProfiles` permissions); and
  `/account` (any authenticated user).
- **Components:** `components/admin/` (the users/roles/profiles list and detail
  editors, including ResourceTagsInput); `components/shared/` (JsonEditor,
  ConfirmModal, ValueTag, DetailField); and the container/header/sidebar shells,
  plus UserTagsInput, in `components/`.
- **State — `src/store/`:** `account` (session identity, launch profiles, and the
  reactive viewers directory consumed by the sharing autocomplete), `admin`
  (server-side users/roles/profiles CRUD), and the root container state. Admin and
  account mutations refresh related state cross-module so the UI reflects live edits.
- **Services — `src/services/`:** `admin`, `account`, and container HTTP wrappers;
  admin/self mutations are sent as POST.

The components, header navigation, and Container view read the current user and
launch profiles from the Vuex store rather than the frozen `window.dockside`
bootstrap, so they reflect edits made in the same session.
