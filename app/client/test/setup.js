// jsdom doesn't implement window.matchMedia at all - App.vue's drawerOpen
// seed calls it directly at data()-init time, and Vuetify's theme setup reads
// prefers-color-scheme through it when plugins/vuetify.js's createVuetify()
// runs at module load, so every test that imports a Vuetify-using component
// needs this defined before that happens. matches: false picks the light
// theme and a closed drawer, the same as a real browser with no dark-mode
// preference and a viewport narrower than 960px.
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

// jsdom has no ResizeObserver either. Vuetify's v-progress-circular, which a
// v-btn renders while its `loading` prop holds, observes its own element's
// size through it at mount, so any test that mounts a loading button needs
// one defined. Observing nothing is enough: no test asserts on a measured
// size, only on the element's presence and state.
window.ResizeObserver = window.ResizeObserver || class {
   observe() {}
   unobserve() {}
   disconnect() {}
};

// Vitest setup (see vitest.config.js's setupFiles): stubs the window.dockside
// bootstrap object that the store modules read at construction time (see
// store/index.js's `containers: window.dockside.containers` and
// store/account.js's createState()). In the real app the server's page HTML
// sets it in an inline <script> before the bundle ever loads - tests need the
// same shape available before any component or store module is imported.
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
