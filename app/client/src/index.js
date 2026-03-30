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
   const p    = store.state.currentUser.permissions.actions;
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
      const p = store.state.currentUser.permissions.actions;
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
   // eslint-disable-next-line no-unused-vars
   scrollBehavior (to, from, savedPosition) {
      // https://v3.router.vuejs.org/guide/advanced/scroll-behavior.html
      return { x: 0, y: 0 };
   },
   mode: 'history' // https://router.vuejs.org/guide/essentials/history-mode.html
});

new Vue({
   router,
   store,
}).$mount('#app');
