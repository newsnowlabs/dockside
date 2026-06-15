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

   // Directory of users/roles offered by the container-sharing autocomplete
   // (UserTagsInput) — seeded from the bootstrap window.dockside.viewers and kept
   // reactive so admin user mutations and self-edits made in this session are
   // reflected without a full reload. A mutable copy so splice/push stay reactive.
   // Normalize name to username here too (matching upsertViewer/setViewers): the
   // server bootstrap only falls back for an undef name, so an empty-string name
   // survives — and a non-admin session never runs fetchUsers to repair it, leaving
   // a blank autocomplete label that can't be matched or distinguished.
   viewers: (window.dockside.viewers || []).map(v => ({ ...v, name: v.name || v.username })),

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

      // Keep the shared viewers directory (consumed by UserTagsInput) in sync. name
      // falls back to the username when absent/empty (as the server bootstrap does),
      // since UserTagsInput lowercases it for autocomplete.
      upsertViewer(state, { username, name, role }) {
         const entry = { username, name: name || username, role };
         const idx = state.viewers.findIndex(v => v.username === username);
         if (idx >= 0) state.viewers.splice(idx, 1, entry);
         else          state.viewers.push(entry);
      },
      removeViewer(state, username) {
         state.viewers = state.viewers.filter(v => v.username !== username);
      },
      // Replace the whole directory from an authoritative user list (e.g. after
      // admin/fetchUsers). This repairs staleness from changes the per-mutation
      // sync can't see — made via the CLI, another browser tab, or direct config
      // edits — by rebuilding from server state on the next admin list fetch.
      setViewers(state, users) {
         state.viewers = (users || []).map(u => ({ username: u.username, name: u.name || u.username, role: u.role }));
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
         const record = await accountApi.updateSelf(data);
         // Reflect a self display-name/role change in the shared viewers directory from
         // the POST response — username is unchanged (not self-editable) and name/role
         // come from the saved record — so it stays correct even if the GET below fails.
         commit('upsertViewer', { username: state.currentUser.username, name: record.name, role: record.role });
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
