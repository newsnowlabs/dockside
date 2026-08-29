import { createApp, configureCompat } from 'vue';
import { createRouter, createWebHistory } from 'vue-router';
import createStore from '@/store';
import vuetify from '@/plugins/vuetify';
import './index.scss';
import App from '@/components/App.vue';

// @vue/compat's MODE 2 has two separate configuration points, not one:
// vite.config.js's compilerOptions.compatConfig controls how .vue SFC
// *templates* compile (Options API, filters, v-model defaults, ...); this
// configureCompat() call controls the *runtime* library's own compat
// behavior. Must run before any other Vue API call.
//
// COMPONENT_V_MODEL/COMPONENT_ASYNC/COMPONENT_FUNCTIONAL: false is a Stage 3
// addition (bootstrap-vue -> Vuetify 3, see docs/plans/vue2-vue3-migration.md)
// and is *runtime*, not compiler-level - not something compilerOptions.
// compatConfig above can reach. All three are MODE 2's "guess whether this
// component is legacy Vue 2 code and translate it if so" checks, and all
// three turned out to guess wrong against Vuetify - a genuinely Vue-3-native
// library with no compat markers of its own - because the check is a pure
// shape/identity test applied to *any* component encountered at runtime,
// with no way to tell "authored for Vue 2" apart from "just happens to match
// the shape Vue 2 code would have":
//   - COMPONENT_V_MODEL rewrites ANY component vnode's modelValue/
//     update:modelValue pair down to value/onModelCompat:input at
//     vnode-creation time. Confirmed live: v-dialog kept receiving updates
//     from v-model correctly, but VDialog's own useProxiedModel() only ever
//     saw the legacy value/onModelCompat:input keys, so it could never tell
//     it was "controlled" and the dialog never opened - no error, no
//     warning, just zero DOM output. Not scoped to our two imperative-modal
//     call sites - left enabled, it would have hit *every* Vuetify v-model
//     usage app-wide (v-text-field, v-select, v-switch, v-tabs,
//     v-navigation-drawer, ...).
//   - COMPONENT_ASYNC treats *any* bare function passed as a vnode type as a
//     legacy Vue 2 async-component factory (`() => import(...)`) unless
//     disabled - Vue's own deprecation message for this feature says as
//     much: "Plain functions will be treated as functional components in
//     non-compat build." Confirmed live: crashed immediately
//     (`Cannot read properties of undefined (reading 'default')`) on the
//     first Vuetify component rendered that internally uses a plain-function
//     functional component (VCard, VField - i.e. v-text-field/v-select/
//     v-textarea, VSwitch, VDataTable, VDataIterator all do), because
//     convertLegacyAsyncComponent() called it with one argument instead of
//     Vue 3's real (props, context) functional-component signature.
//   - COMPONENT_FUNCTIONAL is the same kind of check for the *other* Vue 2
//     functional-component shape (an options object with `functional: true`)
//     - disabled pre-emptively alongside the other two once this pattern was
//     clear, rather than waiting to hit it as a third separate crash.
// None of this touches our own custom components (ChoiceInput, UserTagsInput,
// JsonEditor, ValueTag, ResourceTagsInput, SshEditor, ConfirmModal, ...) -
// they're all plain Options API objects, never bare functions or
// `{functional: true}` objects, and the ones still on value/input (Stage 2)
// are bound by their callers via explicit :value/@input, never v-model/
// :modelValue, so COMPONENT_V_MODEL doesn't touch that binding either way.
//
// INSTANCE_LISTENERS: false is a fourth addition in the same family, found
// the same way: a plain <v-btn @click="..."> silently did nothing (confirmed
// on two independent, unrelated buttons - ConfirmModal's own Cancel, and
// Header's hamburger, both plain v-btn/v-app-bar-nav-icon usage, nothing
// exotic) - the click reached the DOM (a raw addEventListener('click', ...)
// fired), but Vue's own handler never ran, meaning the listener never made it
// onto the rendered root element in the first place. Root cause, traced
// through @vue/compat's own shouldSkipAttr(): under MODE 2,
// INSTANCE_LISTENERS resurrects Vue 2's separate $listeners bucket by
// stripping *every* on*-named key out of $attrs before Vue's normal
// automatic-attrs-fallthrough step ever runs - so an event listener can only
// ever reach a child's root element if that child explicitly declares the
// event in its own `emits` (as v-model's update:modelValue always does) or
// reads $listeners itself (a defunct Vue 2 API no Vuetify component has any
// reason to check). VBtn declares only 'group:selected' in emits, so its own
// internal onClick ran, but any @click *we* write on it - or on anything
// that doesn't declare 'click' as an emit - was silently dropped before
// fallthrough, every time, app-wide. Same shape as the other three: a
// blanket "this must be legacy Vue 2 code" assumption that's wrong for a
// library that was never Vue 2 code to begin with.
configureCompat({
   MODE: 2,
   COMPONENT_V_MODEL: false,
   COMPONENT_ASYNC: false,
   COMPONENT_FUNCTIONAL: false,
   INSTANCE_LISTENERS: false,
});

// Create store before route guards so guards read live currentUser state
// rather than the stale window.dockside.user bootstrap snapshot.
const store = createStore();

function adminTypeGuard(to, from, next) {
   const p    = store.state.account.currentUser.permissions.actions;
   const type = to.params.type;
   const allowedTypes = [];
   if (p.manageUsers)    allowedTypes.push('users', 'roles');
   if (p.manageProfiles) allowedTypes.push('profiles');
   if (allowedTypes.includes(type)) {
      next();
   } else if (p.manageUsers) {
      next('/admin/users');
   } else if (p.manageProfiles) {
      next('/admin/profiles');
   } else {
      next('/');
   }
}

const routes = [
   { path: '/container/:name', name: 'container', component: App },
   { path: '/admin', redirect: () => {
      // A route record with only `beforeEnter` and no component/redirect/
      // children stopped matching under vue-router 4 (confirmed live: the
      // guard never fired at all, not even a failed redirect - the record
      // was simply never selected for '/admin'). `redirect` is the
      // purpose-built feature for this exact "no view of its own, always
      // sends you elsewhere" case, so use that instead of a guard.
      const p = store.state.account.currentUser.permissions.actions;
      if (p.manageUsers)         return '/admin/users';
      else if (p.manageProfiles) return '/admin/profiles';
      else                       return '/';
   }},
   { path: '/admin/:type',     name: 'adminList',   component: App, beforeEnter: adminTypeGuard },
   { path: '/admin/:type/:id', name: 'adminDetail', component: App, beforeEnter: adminTypeGuard },
   { path: '/account',         name: 'account',     component: App },
   { path: '/', component: App },
   { path: '/docs', name: 'docs', beforeEnter() { window.open("/docs/", "docs"); } },
   { path: '/docksideio', name: 'docksideio', beforeEnter() { window.open("https://dockside.io/", "docksideio"); } },
   { path: '/dockside-github', name: 'dockside-github', beforeEnter() { window.open("https://github.com/newsnowlabs/dockside", "dockside-github"); } },
   { path: '/newsnow', name: 'newsnow', beforeEnter() { window.open("https://www.newsnow.co.uk/about", "newsnow"); } },
];

const router = createRouter({
   routes,
   // https://v3.router.vuejs.org/guide/advanced/scroll-behavior.html
   scrollBehavior (to, from) {
      if (to.path === from.path) {
         // A profile switch (nav-click or the launch form's own profile select)
         // replaces most of the form's fields at once — new image, runtime,
         // network, IDE, access and options defaults. Different enough from a
         // single field edit that scrolling back to the top to review the
         // freshly-defaulted form from the top down is more helpful than leaving
         // the user scrolled at a position whose content just changed meaning.
         if (to.query.profile !== from.query.profile) {
            return { x: 0, y: 0 };
         }
         // Any other query-only update on the same route (a single field edit,
         // or the containers-filter select) isn't a real navigation — don't yank
         // scroll position out from under whatever the user was doing.
         return false;
      }
      return { x: 0, y: 0 };
   },
   history: createWebHistory() // https://router.vuejs.org/guide/essentials/history-mode.html
});

// createApp(), not `new Vue({ router, store }).$mount(...)`: that Vue-2-style
// global-API pattern (root-instance `router`/`store` options, relying on an
// earlier `Vue.use(VueRouter)`/`Vue.use(Vuex)` *class* registration to wire up
// the reactive $route/$router/$store plumbing) doesn't carry over cleanly -
// vue-router 4 / Vuex 4 have no such installable class any more, only an
// installable *instance* (`app.use(router)`), so there's nothing left for
// @vue/compat's `new Vue()` shim to auto-detect and wire up: router/store
// passed as bare instance options silently did nothing (confirmed via
// RouterView's injected route context being undefined, and separately via
// router.isReady() never resolving - the initial navigation never started).
// createApp() is the real Vue 3 entry point and fully supports MODE 2
// Options-API components/plugins otherwise, so switching to it here doesn't
// require touching anything else in the app.
const app = createApp({
   // Explicit rather than relying on in-DOM template compilation of the
   // pre-existing markup App.pm's server HTML puts in #app (see App.pm's
   // get_body handler) - matches that markup exactly, so this is a no-op
   // change in what actually renders, just no longer depending on whichever
   // compat/runtime-compilation behavior in-DOM templates need.
   template: '<router-view></router-view>',
});
app.use(router);
app.use(store);
// Real app.use(), unlike bootstrap-vue's install (see Stage 2/3 history
// above for why that one needed the compat *global* Vue.use() instead):
// Vuetify 3 is genuinely Vue-3-native, so its install(app, ...) receiving
// the real app instance is exactly what it expects - no compat translation
// involved. Confirms the app.use()-vs-Vue.use() split really was specific
// to bootstrap-vue's legacy plugin shape, not a general rule.
app.use(vuetify);
app.mount('#app');
