// Account service — self-service API for the session user.
// These endpoints are available to any authenticated user without admin permissions.

import axios from 'axios';

// Returns the session user's derived identity record (same shape as the
// bootstrap window.dockside.user object): permissions.actions, role_as_meta,
// masked gh_token, etc.
export function getSelf() {
   return axios.get('/account').then(r => r.data.data);
}

// Updates the session user's own editable fields (name, email, gh_token,
// ssh_keypairs). Role, permissions, and resources are admin-only writes.
export function updateSelf(data) {
   return axios.post('/account/update', data).then(r => r.data.data);
}

// Returns the profiles the session user is permitted to launch, in the same
// format as the bootstrap window.dockside.profiles object.
export function getLaunchProfiles() {
   return axios.get('/account/profiles').then(r => r.data.data);
}
