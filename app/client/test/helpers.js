import { createRouter, createMemoryHistory } from 'vue-router';
import { mount } from '@vue/test-utils';
import createStore from '@/store';

// Mounts `Component` with a fresh store + router wired up, so components
// that reach for this.$store/this.$route/this.$router work without per-test
// boilerplate. `createMemoryHistory()` avoids depending on jsdom's real
// browser history/location APIs - standard for Vue Router unit tests (the
// old v3 'abstract' mode's v4 equivalent). `storeSetup(store)` lets a test
// seed state before mount (e.g. commit/dispatch into the admin or account
// module). `stubs` is a convenience alias for `global.stubs` (@vue/test-utils
// v2 moved plain top-level `stubs` under `global`).
//
// Deliberately doesn't install BootstrapVue/IconsPlugin as real plugins here
// (unlike the real app - see index.js): bootstrap-vue's install(Vue, config)
// expects a legacy global Vue constructor with a `.prototype` and throws when
// handed the compat-wrapped app instance app.use() actually passes under
// Vue 3 (confirmed live - a real, if currently-cosmetic, mismatch the real
// app also hits, just as a console.warn instead of a throw - see
// ChoiceInput.vue's neighbouring components for the broader story). Since
// these are smoke tests asserting rendered text, not bootstrap-vue-specific
// behavior, letting `b-*` tags render as Vue's default "unresolved
// component" fallback (a warning, not a crash) is an acceptable trade to
// keep the harness itself simple; revisit once bootstrap-vue is gone
// (Stage 3) and this whole question is moot.
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
         plugins: [store, router],
         stubs,
         ...global,
      },
      ...mountOptions,
   });
}
