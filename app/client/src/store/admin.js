// Vuex admin module (namespaced) — state for users, roles, profiles.
import * as api from '@/services/admin';

const createState = () => ({
   users:         [],
   roles:         [],
   profiles:      [],
   hostResources: null, // { runtimes, networks, IDEs, authModes } — loaded once
   // type: 'user' | 'role' | 'profile' | null; id: string | null; mode: 'view' | 'edit'
   selected: { type: null, id: null, mode: 'view' },
   loading:  false,
   error:    null,
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
      renameProfile(state, { oldId, newId }) {
         const p = state.profiles.find(p => p.id === oldId);
         if (p) p.id = newId;
      },

      setSelected(state, { type, id, mode = 'view' }) {
         state.selected = { type, id, mode };
      },
      setSelectedMode(state, mode) {
         state.selected = { ...state.selected, mode };
      },
      clearSelected(state) {
         state.selected = { type: null, id: null, mode: 'view' };
      },
   },

   actions: {
      async fetchAll({ dispatch, rootState }) {
         const p = rootState.currentUser.permissions.actions;
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

      async updateUser({ commit, rootState }, { username, data }) {
         commit('setError', null);
         const record = await api.updateUser(username, data);
         commit('upsertUser', record);
         if (record.username === rootState.currentUser.username) {
            commit('setCurrentUser', {
               name:        record.name,
               email:       record.email,
               role:        record.role,
               // Wrap to match bootstrap shape: permissions.actions.*
               // (CRUD response returns flat { manageUsers: ... }, not { actions: { ... } })
               permissions: { actions: record.permissions || {} },
            }, { root: true });
         }
         return record;
      },

      async updateSelf({ commit }, data) {
         commit('setError', null);
         const record = await api.updateSelf(data);
         commit('upsertUser', record);
         commit('setCurrentUser', { name: record.name, email: record.email }, { root: true });
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

      async updateRole({ commit }, { name, data }) {
         commit('setError', null);
         const record = await api.updateRole(name, data);
         commit('upsertRole', record);
         return record;
      },

      async removeRole({ commit }, name) {
         commit('setError', null);
         await api.removeRole(name);
         commit('removeRole', name);
      },

      // -----------------------------------------------------------------------
      // Profile CRUD
      // -----------------------------------------------------------------------
      async createProfile({ commit, dispatch }, data) {
         commit('setError', null);
         const record = await api.createProfile(data);
         commit('upsertProfile', record);
         dispatch('fetchProfiles', null, { root: true });
         return record;
      },

      async updateProfile({ commit, dispatch }, { id, data }) {
         commit('setError', null);
         const record = await api.updateProfile(id, data);
         commit('upsertProfile', record);
         dispatch('fetchProfiles', null, { root: true });
         return record;
      },

      async removeProfile({ commit, dispatch }, id) {
         commit('setError', null);
         await api.removeProfile(id);
         commit('removeProfile', id);
         dispatch('fetchProfiles', null, { root: true });
      },

      async renameProfile({ commit, dispatch }, { id, newName }) {
         commit('setError', null);
         const result = await api.renameProfile(id, newName);
         commit('renameProfile', { oldId: id, newId: result.id });
         dispatch('fetchProfiles', null, { root: true });
         return result;
      },
   },
};
