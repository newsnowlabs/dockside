import { markRaw } from 'vue';
import { createStore as createVuexStore } from 'vuex';
import { getContainers } from '@/services/container';
import adminModule   from '@/store/admin';
import accountModule from '@/store/account';

const welcomeTextStatusLocalStorageKey = '/dockside/welcomeTextStatus';

// Aliased to createVuexStore on import: this factory is itself also named
// createStore (and exported as the default below) - importing Vuex's own
// createStore under the same name would shadow it and self-recurse.
const createStore = () => createVuexStore({
   strict: process.env.NODE_ENV !== 'production',
   modules: {
      admin:   adminModule,
      account: accountModule,
   },
   state: {
      selectedContainer: { name: undefined, mode: 'view' },
      containersFilter: 'shared',
      // markRaw on every container object: nothing anywhere reads/writes a
      // container's own fields reactively (Container.vue copies into its
      // own local `form` to edit, and every store mutation below replaces
      // the whole array rather than mutating one element in place), so only
      // this array's own top-level reference needs to be reactive - not each
      // container's nested meta/data/permissions structure, re-proxied on
      // every ~1s polling refresh otherwise.
      containers: window.dockside.containers.map(c => markRaw(c)),
      welcomeTextStatus: localStorage.getItem(welcomeTextStatusLocalStorageKey) !== null ?
         parseInt(localStorage.getItem(welcomeTextStatusLocalStorageKey)) : 0,
      // sshInfoModalOpen persists modal state in the store because
      // Container.vue's Setup button and SSHInfo.vue (mounted as an
      // App.vue-level singleton) are siblings with no parent/child
      // relationship, so v-dialog's plain v-model has nowhere shared to
      // live except here.
      sshInfoModalOpen: false,
      // The app-wide snackbar (rendered once in App.vue). Lives in the store,
      // like sshInfoModalOpen above, because any component - via the notifier
      // mixin - needs to raise it, and the single <v-snackbar> that shows it is
      // a sibling of all of them, not a parent.
      snackbar: { show: false, text: '', color: 'error', timeout: 6000 },
   },
   getters: {
      welcomeTextStatus: state => state.welcomeTextStatus,
      isSelected: state => state.selectedContainer.name !== undefined,
      // -4 (docker-create failed) is treated as "launching" alongside -2, so a failed
      // launch keeps the potential for fast-polling (although poll times are currently
      // equal) until the reservation is auto-cleaned away; unlike steady states, -4 is
      // transient.
      haveLaunchingContainers: state => state.containers.some(container =>
         (container.status == -2 && (container.expiryTime === undefined || container.expiryTime === null || container.expiryTime === '')) ||
         container.status == -4
      ),
      haveContainers: state => state.containers.length > 0,
      isEditMode: (state, getters) => getters.isSelected && state.selectedContainer.mode === "edit",
      isPrelaunchMode: (state, getters) => getters.isSelected && state.selectedContainer.name === "new",
   },
   mutations: {
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
         state.containers = containers.map(c => markRaw(c));
      },
      addContainer(state, container) {
         state.containers = state.containers.filter(c => c.id !== container.id).concat(markRaw(container));
      },
      setSshInfoModalOpen(state, open) {
         state.sshInfoModalOpen = open;
      },
      showSnackbar(state, { text, color = 'error', timeout = 6000 }) {
         // Replace the whole object so a rapid second message re-triggers the
         // snackbar even while the first is still visible (Vuetify re-opens on a
         // fresh truthy model-value, but only if the reference actually changes).
         state.snackbar = { show: true, text, color, timeout };
      },
      hideSnackbar(state) {
         state.snackbar = { ...state.snackbar, show: false };
      },
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
   }
});

export default createStore;
