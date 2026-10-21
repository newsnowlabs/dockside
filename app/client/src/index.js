import { createApp } from 'vue';
import { createRouter, createWebHistory } from 'vue-router';
import createStore from '@/store';
import { trackInputModality } from '@/utilities/input-modality';
import vuetify from '@/plugins/vuetify';
import './index.scss';
// The IBM Plex typefaces settings.scss and the components name, built into the bundle
// rather than fetched from a font service, in the four weights the styles use.
import '@fontsource/ibm-plex-sans/400.css';
import '@fontsource/ibm-plex-sans/500.css';
import '@fontsource/ibm-plex-sans/600.css';
import '@fontsource/ibm-plex-sans/700.css';
import '@fontsource/ibm-plex-mono/400.css';
import '@fontsource/ibm-plex-mono/500.css';
import '@fontsource/ibm-plex-mono/600.css';
import '@fontsource/ibm-plex-mono/700.css';
import App from '@/components/App.vue';

// The root element's data-input says whether keyboard or pointer was used last (index.scss).
trackInputModality();

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
      // vue-router 4 only matches a route record that has a name, a
      // component or a redirect, so an unnamed record with only
      // `beforeEnter` never matches. `redirect` is the purpose-built feature
      // for a route with no view of its own that always sends you elsewhere.
      const p = store.state.account.currentUser.permissions.actions;
      if (p.manageUsers)         return '/admin/users';
      else if (p.manageProfiles) return '/admin/profiles';
      else                       return '/';
   }},
   { path: '/admin/:type',     name: 'adminList',   component: App, beforeEnter: adminTypeGuard },
   { path: '/admin/:type/:id', name: 'adminDetail', component: App, beforeEnter: adminTypeGuard },
   { path: '/account',         name: 'account',     component: App },
   { path: '/', component: App },
];

const router = createRouter({
   routes,
   // https://router.vuejs.org/guide/advanced/scroll-behavior.html
   scrollBehavior (to, from) {
      if (to.path === from.path) {
         // A profile switch (nav-click or the launch form's own profile select)
         // replaces most of the form's fields at once — new image, runtime,
         // network, IDE, access and options defaults. Different enough from a
         // single field edit that scrolling back to the top to review the
         // freshly-defaulted form from the top down is more helpful than leaving
         // the user scrolled at a position whose content just changed meaning.
         if (to.query.profile !== from.query.profile) {
            return { top: 0 };
         }
         // Any other query-only update on the same route (a single field edit,
         // or the containers-filter select) isn't a real navigation — don't yank
         // scroll position out from under whatever the user was doing.
         return false;
      }
      return { top: 0 };
   },
   history: createWebHistory() // https://router.vuejs.org/guide/essentials/history-mode.html
});

// A chunk this page loads on demand (the admin screens) is missing when the
// server has been upgraded since the page loaded: the page still names the
// previous build's files, and each build replaces them. Vite raises
// vite:preloadError when such a load fails; reloading fetches the page for the
// current build. Reloads at most once in RELOAD_WINDOW_MS, so a chunk missing
// for another reason surfaces as the error rather than a reload loop.
const RELOAD_KEY = 'dockside:preloadErrorReloadAt';
const RELOAD_WINDOW_MS = 10000;
window.addEventListener('vite:preloadError', (event) => {
   let last = 0;
   try {
      last = Number(sessionStorage.getItem(RELOAD_KEY)) || 0;
   }
   catch (e) {
      return; // No session storage: without the loop guard, let the error stand.
   }
   if (Date.now() - last < RELOAD_WINDOW_MS) return;
   try {
      sessionStorage.setItem(RELOAD_KEY, String(Date.now()));
   }
   catch (e) {
      return;
   }
   event.preventDefault();
   window.location.reload();
});

// createApp() is Vue 3's app-instance entry point: router and store are wired
// up as installable plugin instances (`app.use(router)`, `app.use(store)`).
const app = createApp({
   // Explicit template string, matching exactly the markup the server's page
   // HTML puts in #app, rather than relying on in-DOM template compilation of
   // that markup.
   template: '<router-view></router-view>',
});
app.use(router);
app.use(store);
// Vuetify 3 installs as an ordinary plugin on the app instance.
app.use(vuetify);
app.mount('#app');
