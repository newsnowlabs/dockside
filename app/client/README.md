# Dockside Web Client

The browser single-page app — Vue 2 + Vuex + Vue Router, bundled with webpack and
served by the Perl server.

## Build / develop

```sh
cd dockside/app/client
npm install        # install dependencies
npm run build      # build dist/ (served by app/server/lib/App.pm)
npm run start      # watch and rebuild on change
```

Lint and build checks also run from the repo root: `./test.sh --only vue`,
`--only eslint`, `--only stylelint`.

## Build outputs

`npm run build` emits `dist/main.js` and `dist/main.css`, which the server serves
as separately-cacheable `/assets/main.{js,css}` (no longer inlined into the page
HTML).

## Layout

- **Entry point — `src/index.js`:** creates the Vuex store *before* the router (so
  the route guards can read the live current user), registers the store modules,
  and defines the routes behind permission-aware guards.
- **Routes / layouts:** the default container view; `/admin/users`, `/admin/roles`,
  `/admin/profiles` (gated on the `manageUsers` / `manageProfiles` permissions); and
  `/account` (any authenticated user).
- **Components:** `components/admin/` (the users/roles/profiles list and detail
  editors); `components/shared/` (JsonEditor, ConfirmModal, ValueTag,
  ResourceTagsInput, UserTagsInput); and the container/header/sidebar shells.
- **State — `src/store/`:** `account` (session identity, launch profiles, and the
  reactive viewers directory consumed by the sharing autocomplete), `admin`
  (server-side users/roles/profiles CRUD), and the root container state. Admin and
  account mutations refresh related state cross-module so the UI reflects live edits.
- **Services — `src/services/`:** `admin`, `account`, and container HTTP wrappers;
  admin/self mutations are sent as POST.

The components, header navigation, and Container view read the current user and
launch profiles from the Vuex store rather than the frozen `window.dockside`
bootstrap, so they reflect edits made in the same session.
