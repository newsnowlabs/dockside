import { createRouter, createMemoryHistory } from 'vue-router';
import { mount } from '@vue/test-utils';
import createStore from '@/store';
import vuetify from '@/plugins/vuetify';

// Mounts `Component` with a fresh store + router wired up, so components
// that reach for this.$store/this.$route/this.$router work without per-test
// boilerplate. `createMemoryHistory()` avoids depending on jsdom's real
// browser history/location APIs - standard for Vue Router unit tests (the
// old v3 'abstract' mode's v4 equivalent). `storeSetup(store)` lets a test
// seed state before mount (e.g. commit/dispatch into the admin or account
// module). `stubs` is a convenience alias for `global.stubs` (@vue/test-utils
// v2 moved plain top-level `stubs` under `global`).
//
// Installs the real Vuetify plugin: Vuetify's own components throw outright
// without it ("[Vuetify] Could not find defaults instance"). Vuetify is
// Vue-3-native and installs via plugin, matching the real app at index.js -
// no special-casing needed here.
export function mountApp(Component, { storeSetup, routerOptions, props, stubs, global, ...mountOptions } = {}) {
   const store = createStore();
   if (storeSetup) storeSetup(store);
   const router = createRouter({
      history: createMemoryHistory(),
      routes: [{ path: '/:pathMatch(.*)*', component: { template: '<div/>' } }],
      ...routerOptions,
   });
   return mount(Component, {
      props,
      global: {
         plugins: [store, router, vuetify],
         stubs,
         ...global,
      },
      ...mountOptions,
   });
}
