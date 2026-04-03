// Vuex account module (namespaced) — session user identity and launch profiles.
// All state here belongs to the currently logged-in user and is independent of
// admin management operations.
import * as accountApi from '@/services/account';

const createState = () => ({
   // The session user's derived identity record — same shape as the bootstrap
   // window.dockside.user object (permissions.actions, role_as_meta, etc.).
   currentUser:    { ...window.dockside.user },

   // Profiles the session user is permitted to launch — same shape as the
   // bootstrap window.dockside.profiles object.
   launchProfiles: window.dockside.profiles,

   // Error shown on the /account page when a self-edit refresh fails.
   accountError:   null,
});

export default {
   namespaced: true,

   state: createState,

   mutations: {
      setCurrentUser(state, patch) {
         const merged = { ...state.currentUser, ...patch };
         // Derive role_as_meta from role so it never goes stale after a role change.
         if (patch.role !== undefined) {
            merged.role_as_meta = patch.role ? ('role:' + patch.role) : undefined;
         }
         state.currentUser = merged;
      },

      setLaunchProfiles(state, profiles) {
         state.launchProfiles = profiles;
      },

      setAccountError(state, v) {
         state.accountError = v;
      },
   },

   actions: {
      // Refresh session identity from the server (GET /account).
      // Throws on failure so callers can surface the error.
      async fetchSelf({ commit }) {
         const record = await accountApi.getSelf();
         commit('setCurrentUser', record);
      },

      // Save self-editable fields (name, email, gh_token, ssh), then re-read
      // derived identity from server.  If the user also has manageUsers, refresh
      // the admin users list so the admin view stays consistent.
      async updateSelf({ commit, dispatch, state }, data) {
         commit('setAccountError', null);
         await accountApi.updateSelf(data);
         try {
            await dispatch('fetchSelf');
         } catch (e) {
            commit('setAccountError', 'Save succeeded but session state could not be refreshed — please reload the page');
         }
         if (state.currentUser.permissions.actions.manageUsers) {
            dispatch('admin/fetchUsers', null, { root: true });
         }
      },

      // Refresh the launch-profile cache (GET /account/profiles).  Non-fatal —
      // stale profiles still allow the user to launch existing containers.
      async fetchLaunchProfiles({ commit }) {
         try {
            const profiles = await accountApi.getLaunchProfiles();
            commit('setLaunchProfiles', profiles);
         } catch (e) {
            // Non-fatal — stale profiles still work
         }
      },
   },
};
