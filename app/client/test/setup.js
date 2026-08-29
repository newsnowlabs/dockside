import { configureCompat } from 'vue';

// Matches index.js's own call exactly (see that file's own comment for the
// full story on each flag) - must run before any other Vue API use. This is
// a genuinely separate configureCompat() call from index.js's, not something
// that's shared automatically, so index.js's Stage 3 additions
// (COMPONENT_V_MODEL/COMPONENT_ASYNC/COMPONENT_FUNCTIONAL/INSTANCE_LISTENERS,
// all false) went missing here for a while without erroring - nothing in the
// pre-Stage-3 test suite exercised a real Vuetify component, so there was
// nothing to trip the same bugs on. First symptom once one did (UserDetail.spec.js/
// ProfileDetail.spec.js, the moment their forms started using real v-btn/
// v-text-field/etc.): the exact COMPONENT_ASYNC crash
// ("Cannot read properties of undefined (reading 'default')" inside
// Vuetify's LoaderSlot) index.js's own comment already documents from the
// real app.
configureCompat({
   MODE: 2,
   COMPONENT_V_MODEL: false,
   COMPONENT_ASYNC: false,
   COMPONENT_FUNCTIONAL: false,
   INSTANCE_LISTENERS: false,
});

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
