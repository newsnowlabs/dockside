import { createApp } from 'vue';
import { createRouter, createWebHistory } from 'vue-router';
import createStore from '@/store';
import vuetify from '@/plugins/vuetify';
import './index.scss';
import App from '@/components/App.vue';

// No more configureCompat() call here: Stage 4 of
// docs/plans/vue2-vue3-migration.md (dockside-admin repo) dropped
// @vue/compat entirely (see that stage's write-up for the full account of
// what MODE 2 plus the four flags this used to set - COMPONENT_V_MODEL,
// COMPONENT_ASYNC, COMPONENT_FUNCTIONAL, INSTANCE_LISTENERS - were each
// working around, none of which apply once the library isn't in the build).

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
