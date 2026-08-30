// No configureCompat() here any more - Stage 4 of
// docs/plans/vue2-vue3-migration.md (dockside-admin repo) dropped
// @vue/compat from the build entirely, so there's no compat runtime left to
// configure, in tests or in index.js.

// jsdom doesn't implement window.matchMedia at all - both App.vue's
// drawerOpen seed and plugins/vuetify.js's initialTheme() call it directly
// (module/data()-init time, before any component mounts), so every test
// that imports a Vuetify-using component needs this defined before that
// happens. matches: false picks light/desktop-width defaults, same as a
// real browser with no dark-mode/narrow-viewport preference set.
window.matchMedia = window.matchMedia || function (query) {
   return {
      matches: false,
      media: query,
      addListener() {},
      removeListener() {},
      addEventListener() {},
      removeEventListener() {},
      dispatchEvent() { return false; },
   };
};

// Vitest setup (see vitest.config.js's setupFiles): stubs the window.dockside
// bootstrap object that the store modules read at construction time (see
// store/index.js's `containers: window.dockside.containers` and
// store/account.js's createState()). In the real app this is injected by
// App.pm's server-rendered <script> tag before the bundle ever loads (see
// App.pm:583-601 / the get_body handler) - tests need the same shape
// available before any component or store module is imported.
window.dockside = {
   user: {
      id: 1,
      username: 'admin',
      name: 'Test Admin',
      email: 'admin@example.com',
      role: 'admin',
      role_as_meta: 'role:admin',
      permissions: { actions: {} },
   },
   profiles: {},
   containers: [],
   viewers: [],
   dummyReservation: null,
};
