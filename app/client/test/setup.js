import { configureCompat } from 'vue';

// Matches index.js's own call, which must run before any other Vue API use -
// without it, mounting a component that uses a Vue-2-style plugin (like
// BootstrapVue's install(Vue, config)) crashes instead of just compat-warning,
// since nothing here is in MODE 2 by default (confirmed live: bootstrap-vue's
// setConfig() threw reading a property off the app instance it was handed).
configureCompat({ MODE: 2 });

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
