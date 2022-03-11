import Vue from 'vue';
import VueRouter from 'vue-router';
import Vuex from 'vuex';
import { BootstrapVue } from 'bootstrap-vue';
import createStore from '@/store';
import './index.scss';
import App from '@/components/App.vue';

Vue.use(VueRouter);
Vue.use(Vuex);
Vue.use(BootstrapVue);

const routes = [
   { path: '/container/:name', name: 'container', component: App },
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
   store: createStore()
}).$mount('#app');
