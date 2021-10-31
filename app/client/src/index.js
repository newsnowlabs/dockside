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
   { path: '/docs', name: 'docs', beforeEnter() { window.open("/docs/", "_blank"); } }
];

const router = new VueRouter({
   routes,
   mode: 'history' // https://router.vuejs.org/guide/essentials/history-mode.html
});

new Vue({
   router,
   store: createStore()
}).$mount('#app');
