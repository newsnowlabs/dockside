import Vue from 'vue';
import VueRouter from 'vue-router';
import Vuex from 'vuex';
import { BootstrapVue, IconsPlugin } from 'bootstrap-vue';
import createStore from '@/store';
import './index.scss';
import App from '@/components/App.vue';

Vue.use(VueRouter);
Vue.use(Vuex);
Vue.use(BootstrapVue);
Vue.use(IconsPlugin);

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
   { path: '/admin', beforeEnter(to, from, next) {
      const p = store.state.account.currentUser.permissions.actions;
      if (p.manageUsers)         next('/admin/users');
      else if (p.manageProfiles) next('/admin/profiles');
      else                       next('/');
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

const router = new VueRouter({
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
   mode: 'history' // https://router.vuejs.org/guide/essentials/history-mode.html
});

new Vue({
   router,
   store,
}).$mount('#app');
