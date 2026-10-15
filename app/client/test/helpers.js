import { createRouter, createMemoryHistory } from 'vue-router';
import { mount } from '@vue/test-utils';
import createStore from '@/store';
import vuetify from '@/plugins/vuetify';

// Mounts `Component` with a fresh store + router wired up, so components
// that reach for this.$store/this.$route/this.$router work without per-test
// boilerplate. `createMemoryHistory()` avoids depending on jsdom's real
// browser history/location APIs - standard for Vue Router unit tests.
// `storeSetup(store)` lets a test seed state before mount (e.g.
// commit/dispatch into the admin or account module). `stubs` is a
// convenience alias for `global.stubs` (@vue/test-utils v2 takes `stubs`
// under `global`, not as a top-level mount option).
//
// Installs the real Vuetify plugin: Vuetify's own components throw outright
// without it ("[Vuetify] Could not find defaults instance"). It installs as
// an ordinary plugin, the same way the real app does in index.js.
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
