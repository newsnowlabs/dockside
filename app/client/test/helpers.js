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
// Installs the real Vuetify plugin (unlike bootstrap-vue before it - see the
// old version of this comment in git history): Vuetify's own components
// throw outright without it ("[Vuetify] Could not find defaults instance",
// confirmed live the moment UserDetail.vue/ProfileDetail.vue's converted
// forms started using real v-btn/v-text-field/etc. in Stage 3), not the
// bootstrap-vue-install-onto-a-legacy-Vue-constructor mismatch this comment
// used to describe. Vuetify is genuinely Vue-3-native and installs the same
// way here as in the real app (index.js) - no special-casing needed, unlike
// that mismatch ever required.
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
