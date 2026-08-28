import Vuex from 'vuex';
import VueRouter from 'vue-router';
import { BootstrapVue, IconsPlugin } from 'bootstrap-vue';
import { createLocalVue, mount } from '@vue/test-utils';
import createStore from '@/store';

// Registers the same global plugins src/index.js registers on the real Vue
// constructor (Vuex, VueRouter, BootstrapVue, IconsPlugin), scoped to a
// localVue per @vue/test-utils convention so tests don't leak global Vue
// state across files.
export function createTestLocalVue() {
   const localVue = createLocalVue();
   localVue.use(Vuex);
   localVue.use(VueRouter);
   localVue.use(BootstrapVue);
   localVue.use(IconsPlugin);
   return localVue;
}

// Mounts `Component` with a fresh store + router + localVue wired up the same
// way src/index.js wires the real app, so components that reach for
// this.$store/this.$route/this.$router work without per-test boilerplate.
// `abstract` router mode avoids depending on jsdom's history/location APIs -
// standard for Vue Router unit tests. `storeSetup(store)` lets a test seed
// state before mount (e.g. commit/dispatch into the admin or account module).
export function mountApp(Component, { storeSetup, routerOptions, ...mountOptions } = {}) {
   const localVue = createTestLocalVue();
   const store = createStore();
   if (storeSetup) storeSetup(store);
   const router = new VueRouter({ mode: 'abstract', ...routerOptions });
   return mount(Component, { localVue, store, router, ...mountOptions });
}
