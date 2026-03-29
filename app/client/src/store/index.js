import Vuex from 'vuex';
import axios from 'axios';
import { getContainers } from '@/services/container';
import adminModule from '@/store/admin';

const welcomeTextStatusLocalStorageKey = '/dockside/welcomeTextStatus';

const createStore = () => new Vuex.Store({
   strict: process.env.NODE_ENV !== 'production',
   modules: {
      admin: adminModule,
   },
   state: {
      currentUser: { ...window.dockside.user },
      selectedContainer: { name: undefined, mode: 'view' },
      containersFilter: 'shared',
      containers: window.dockside.containers,
      profiles: window.dockside.profiles,
      welcomeTextStatus: localStorage.getItem(welcomeTextStatusLocalStorageKey) !== null ?
         parseInt(localStorage.getItem(welcomeTextStatusLocalStorageKey)) : 0
   },
   getters: {
      welcomeTextStatus: state => state.welcomeTextStatus,
      isSelected: state => state.selectedContainer.name !== undefined,
      haveLaunchingContainers: state => state.containers.some(container =>
         (container.status == -2 && (container.expiryTime === undefined || container.expiryTime === null || container.expiryTime === ''))
      ),
      haveContainers: state => state.containers.length > 0,
      isEditMode: (state, getters) => getters.isSelected && state.selectedContainer.mode === "edit",
      isPrelaunchMode: (state, getters) => getters.isSelected && state.selectedContainer.name === "new",
   },
   mutations: {
      setCurrentUser(state, patch) {
         state.currentUser = { ...state.currentUser, ...patch };
      },
      updateWelcomeTextStatus(state, status) {
         state.welcomeTextStatus = status;
         localStorage.setItem(welcomeTextStatusLocalStorageKey, status);
      },
      updateSelectedContainerName(state, name) {
         state.selectedContainer.name = name;
      },
      updateSelectedContainerMode(state, mode) {
         state.selectedContainer.mode = mode;
      },
      updateContainersFilter(state, containersFilter) {
         state.containersFilter = containersFilter || 'shared';
      },
      updateContainers(state, containers) {
         state.containers = containers;
      },
      updateProfiles(state, profiles) {
         state.profiles = profiles;
      },
      addContainer(state, container) {
         state.containers = state.containers.filter(c => c.id !== container.id).concat(container);
      }
   },
   actions: {
      updateWelcomeTextStatus({ state, commit }, status) {
         if (state.welcomeTextStatus !== status) {
            commit('updateWelcomeTextStatus', status);
         }
      },
      updateSelectedContainerName({ state, commit }, name) {
         if (state.selectedContainer.name !== name) {
            commit('updateSelectedContainerName', name);
         }
         if (state.selectedContainer.mode !== 'view') {
            commit('updateSelectedContainerMode', 'view');
         }
      },
      updateSelectedContainerMode({ state, commit }, mode) {
         if (state.selectedContainer.mode !== mode) {
            commit('updateSelectedContainerMode', mode);
         }
      },
      updateContainersFilter({ state, commit }, containersFilter) {
         if (state.containersFilter !== containersFilter) {
            commit('updateContainersFilter', containersFilter);
         }
      },
      updateContainers(context) {
         return getContainers()
            .then(data => { if(data !== undefined) { context.commit('updateContainers', data); } });
      },
      setContainers(context, data) {
         context.commit('updateContainers', data);
      },
      addContainer(context, container) {
         context.commit('addContainer', container);
      },
      fetchProfiles({ commit }) {
         return axios.get('/profiles/mine')
            .then(r => { commit('updateProfiles', r.data.data); })
            .catch(() => {});   // non-fatal — stale profiles still work
      },
   }
});

export default createStore;
