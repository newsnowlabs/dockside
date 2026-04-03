// Vuex admin module (namespaced: 'admin') — manages server-side users, roles,
// and profiles for admin CRUD operations.  State is kept separate from the
// account module (which holds the session user's own identity) so that
// admin operations on other users don't interfere with the session user's state.
import * as api from '@/services/admin';

const createState = () => ({
   users:         [],
   roles:         [],
   profiles:      [],
   hostResources: null, // { runtimes, networks, IDEs, authModes } — loaded once
   // type: 'user' | 'role' | 'profile' | null; id: string | null; mode: 'view' | 'edit'
   selected: { type: null, id: null, mode: 'view' },
   loading:       false,
   error:         null,  // admin-list fetch/mutation errors (shown on admin routes)
});

export default {
   namespaced: true,

   state: createState,

   getters: {
      selectedUser(state) {
         return state.users.find(u => u.username === state.selected.id) || null;
      },
      selectedRole(state) {
         return state.roles.find(r => r.name === state.selected.id) || null;
      },
      selectedProfile(state) {
         return state.profiles.find(p => p.id === state.selected.id) || null;
      },
      isEditMode(state) {
         return state.selected.mode === 'edit';
      },
      isNewItem(state) {
         return state.selected.id === 'new';
      },
      roleNames(state) {
         return state.roles.map(r => r.name);
      },
   },

   mutations: {
      setLoading(state, v)  { state.loading = v; },
      setError(state, v)    { state.error   = v; },

      setUsers(state, list)          { state.users         = list; },
      setRoles(state, list)          { state.roles         = list; },
      setProfiles(state, list)       { state.profiles      = list; },
      setHostResources(state, data)  { state.hostResources = data; },

      // splice() is used rather than [...list] replacement to trigger Vue 2
      // reactivity on the array element (Vue 2 can't detect direct index writes).
      upsertUser(state, user) {
         const idx = state.users.findIndex(u => u.username === user.username);
         if (idx >= 0) state.users.splice(idx, 1, user);
         else          state.users.push(user);
      },
      removeUser(state, username) {
         state.users = state.users.filter(u => u.username !== username);
      },

      upsertRole(state, role) {
         const idx = state.roles.findIndex(r => r.name === role.name);
         if (idx >= 0) state.roles.splice(idx, 1, role);
         else          state.roles.push(role);
      },
      removeRole(state, name) {
         state.roles = state.roles.filter(r => r.name !== name);
      },

      upsertProfile(state, profile) {
         const idx = state.profiles.findIndex(p => p.id === profile.id);
         if (idx >= 0) state.profiles.splice(idx, 1, profile);
         else          state.profiles.push(profile);
      },
      removeProfile(state, id) {
         state.profiles = state.profiles.filter(p => p.id !== id);
      },
      // Update the in-memory profile id after a server-side rename.  The profile
      // body (name, active, etc.) is unchanged; only the 'id' field is mutated.
      renameProfile(state, { oldId, newId }) {
         const p = state.profiles.find(p => p.id === oldId);
         if (p) p.id = newId;
      },

      // setSelected drives AdminMain's detail-pane rendering (which component to show).
      // mode: 'view' | 'edit' — detail components read this via the isEditMode getter.
      setSelected(state, { type, id, mode = 'view' }) {
         state.selected = { type, id, mode };
      },
      setSelectedMode(state, mode) {
         state.selected = { ...state.selected, mode };
      },
      // clearSelected hides the detail pane and shows the AdminMain placeholder.
      // Called when navigating to a list route (no :id param) or after item deletion.
      clearSelected(state) {
         state.selected = { type: null, id: null, mode: 'view' };
      },
   },

   actions: {
      async fetchAll({ dispatch, rootState }) {
         const p = rootState.account.currentUser.permissions.actions;
         const fetches = [dispatch('fetchResources')];
         if (p.manageUsers)    fetches.push(dispatch('fetchUsers'), dispatch('fetchRoles'));
         if (p.manageProfiles) fetches.push(dispatch('fetchProfiles'));
         await Promise.all(fetches);
      },

      async fetchUsers({ commit }) {
         commit('setLoading', true);
         try {
            const list = await api.listUsers();
            commit('setUsers', list);
         } catch (e) {
            commit('setError', e.message || 'Failed to load users');
         } finally {
            commit('setLoading', false);
         }
      },

      async fetchRoles({ commit }) {
         commit('setLoading', true);
         try {
            const list = await api.listRoles();
            commit('setRoles', list);
         } catch (e) {
            commit('setError', e.message || 'Failed to load roles');
         } finally {
            commit('setLoading', false);
         }
      },

      async fetchProfiles({ commit }) {
         commit('setLoading', true);
         try {
            const list = await api.listProfiles();
            commit('setProfiles', list);
         } catch (e) {
            commit('setError', e.message || 'Failed to load profiles');
         } finally {
            commit('setLoading', false);
         }
      },

      async fetchResources({ commit }) {
         try {
            const data = await api.getResources();
            commit('setHostResources', data);
         } catch (e) {
            // Non-fatal — admin UI works without resource suggestions
         }
      },

      // -----------------------------------------------------------------------
      // User CRUD
      // -----------------------------------------------------------------------
      async createUser({ commit }, data) {
         commit('setError', null);
         const record = await api.createUser(data);
         commit('upsertUser', record);
         return record;
      },

      async updateUser({ commit, dispatch, rootState }, { username, data }) {
         commit('setError', null);
         const record = await api.updateUser(username, data);
         commit('upsertUser', record);
         // If the admin just edited their own user record, refresh the account module
         // so the header and other session-derived UI reflect the updated name/email.
         // Failure is non-fatal (save already succeeded) but surfaced so the user
         // knows to reload if the UI looks stale.
         if (record.username === rootState.account.currentUser.username) {
            try {
               await dispatch('account/fetchSelf', null, { root: true });
            } catch (e) {
               commit('setError', 'Save succeeded but session state could not be refreshed — please reload the page');
            }
         }
         return record;
      },

      async removeUser({ commit }, username) {
         commit('setError', null);
         await api.removeUser(username);
         commit('removeUser', username);
      },

      // -----------------------------------------------------------------------
      // Role CRUD
      // -----------------------------------------------------------------------
      async createRole({ commit }, data) {
         commit('setError', null);
         const record = await api.createRole(data);
         commit('upsertRole', record);
         return record;
      },

      async updateRole({ commit, dispatch, rootState }, { name, data }) {
         commit('setError', null);
         const record = await api.updateRole(name, data);
         commit('upsertRole', record);
         // If the current session user's role was just edited, their effective
         // permissions and role_as_meta may have changed.  Re-fetch the account
         // module's currentUser so any permission-gated UI updates immediately
         // (e.g. nav items, admin sections) rather than requiring a page reload.
         // Failure is non-fatal; the role save already succeeded.
         if (rootState.account.currentUser.role === name) {
            try {
               await dispatch('account/fetchSelf', null, { root: true });
            } catch (e) {
               commit('setError', 'Role saved but session state could not be refreshed — please reload the page');
            }
         }
         return record;
      },

      async removeRole({ commit }, name) {
         commit('setError', null);
         await api.removeRole(name);
         commit('removeRole', name);
      },

      // -----------------------------------------------------------------------
      // Profile CRUD
      // After each mutation, dispatch account/fetchLaunchProfiles so the
      // Container.vue launch form immediately reflects the new profile set.
      // This dispatch is intentionally not awaited — the launch form works fine
      // with stale data and the refresh is best-effort.
      // -----------------------------------------------------------------------
      async createProfile({ commit, dispatch }, data) {
         commit('setError', null);
         const record = await api.createProfile(data);
         commit('upsertProfile', record);
         dispatch('account/fetchLaunchProfiles', null, { root: true });
         return record;
      },

      async updateProfile({ commit, dispatch }, { id, data }) {
         commit('setError', null);
         const record = await api.updateProfile(id, data);
         commit('upsertProfile', record);
         dispatch('account/fetchLaunchProfiles', null, { root: true });
         return record;
      },

      async removeProfile({ commit, dispatch }, id) {
         commit('setError', null);
         await api.removeProfile(id);
         commit('removeProfile', id);
         dispatch('account/fetchLaunchProfiles', null, { root: true });
      },

      async renameProfile({ commit, dispatch }, { id, newName }) {
         commit('setError', null);
         const result = await api.renameProfile(id, newName);
         commit('renameProfile', { oldId: id, newId: result.id });
         dispatch('account/fetchLaunchProfiles', null, { root: true });
         return result;
      },
   },
};
