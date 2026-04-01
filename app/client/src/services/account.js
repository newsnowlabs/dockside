// Account service — self-service API for the session user.
// These endpoints are available to any authenticated user without admin permissions.

import axios from 'axios';

// Guard against responses that are not a plain data object.
//
// When the server is in the process of restarting (or is running an older
// version that doesn't recognise an endpoint), nginx may return a 302 redirect
// to an HTML login/error page.  Axios follows the redirect and the final
// response is HTML, leaving r.data.data as undefined.  Without this guard,
// downstream code would call commit('setCurrentUser', undefined) which throws a
// TypeError deep inside Vuex and crashes silently.
//
// Throwing here instead means the reject path in the Vuex action is taken,
// which surfaces a human-readable error to the user (or a recoverable no-op,
// depending on the caller).
function assertDataObject(data, endpoint) {
   if (!data || typeof data !== 'object' || Array.isArray(data)) {
      throw new Error(`Unexpected response from ${endpoint} — server may need to be restarted`);
   }
   return data;
}

// Returns the session user's derived identity record (same shape as the
// bootstrap window.dockside.user object): permissions.actions, role_as_meta,
// masked gh_token, etc.
export function getSelf() {
   return axios.get('/me').then(r => assertDataObject(r.data.data, '/me'));
}

// Updates the session user's own editable fields (name, email, gh_token,
// ssh_keypairs). Role, permissions, and resources are admin-only writes.
export function updateSelf(data) {
   return axios.post('/me/update', data).then(r => assertDataObject(r.data.data, '/me/update'));
}

// Returns the profiles the session user is permitted to launch, in the same
// format as the bootstrap window.dockside.profiles object.
export function getLaunchProfiles() {
   return axios.get('/me/profiles').then(r => assertDataObject(r.data.data, '/me/profiles'));
}
