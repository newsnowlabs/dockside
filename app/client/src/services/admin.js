// Admin API service — users, roles, profiles, and self-service account editing.
// Follows the same axios pattern as services/container.js.
// Mutation endpoints (create/update) for users and profiles use POST with a
// JSON body so large payloads (e.g. profile JSON) don't hit URL length limits.
// Role mutations remain GET/query-string because role records are small.

import axios from 'axios';

// Guard against 302→HTML→undefined responses (server restart / version mismatch).
// Without these guards, a redirect would leave r.data.data as undefined, causing
// silent state corruption (e.g. state.users = undefined crashes v-for templates).
function assertObj(data, ep) {
   if (!data || typeof data !== 'object' || Array.isArray(data))
      throw new Error(`Unexpected response from ${ep} — server may need to be restarted`);
   return data;
}
function assertArr(data, ep) {
   if (!Array.isArray(data))
      throw new Error(`Unexpected response from ${ep} — server may need to be restarted`);
   return data;
}

// ---------------------------------------------------------------------------
// Users
// ---------------------------------------------------------------------------

export function listUsers() {
   return axios.get('/users').then(r => assertArr(r.data.data, '/users'));
}

export function getUser(username, sensitive = false) {
   const params = sensitive ? { sensitive: 1 } : {};
   return axios.get(`/users/${encodeURIComponent(username)}`, { params }).then(r => assertObj(r.data.data, `/users/${username}`));
}

export function createUser(data) {
   return axios.post('/users/create', data).then(r => assertObj(r.data.data, '/users/create'));
}

export function updateUser(username, data) {
   return axios.post(`/users/${encodeURIComponent(username)}/update`, data).then(r => assertObj(r.data.data, `/users/${username}/update`));
}

export function removeUser(username) {
   return axios.get(`/users/${encodeURIComponent(username)}/remove`).then(r => assertObj(r.data.data, `/users/${username}/remove`));
}

// ---------------------------------------------------------------------------
// Roles
// ---------------------------------------------------------------------------

export function listRoles() {
   return axios.get('/roles').then(r => assertArr(r.data.data, '/roles'));
}

export function getRole(name) {
   return axios.get(`/roles/${encodeURIComponent(name)}`).then(r => assertObj(r.data.data, `/roles/${name}`));
}

export function createRole(data) {
   return axios.post('/roles/create', data).then(r => assertObj(r.data.data, '/roles/create'));
}

export function updateRole(name, data) {
   return axios.post(`/roles/${encodeURIComponent(name)}/update`, data).then(r => assertObj(r.data.data, `/roles/${name}/update`));
}

export function removeRole(name) {
   return axios.get(`/roles/${encodeURIComponent(name)}/remove`).then(r => assertObj(r.data.data, `/roles/${name}/remove`));
}

// ---------------------------------------------------------------------------
// Profiles
// ---------------------------------------------------------------------------

export function listProfiles() {
   return axios.get('/profiles').then(r => assertArr(r.data.data, '/profiles'));
}

export function getProfile(id) {
   return axios.get(`/profiles/${encodeURIComponent(id)}`).then(r => assertObj(r.data.data, `/profiles/${id}`));
}

// createProfile — POST with JSON body.
// `data` must include `id` plus the profile body fields.
// The caller should pass `_json` as a JSON-stringified version of the profile
// body, alongside the simple scalar fields.
export function createProfile(data) {
   return axios.post('/profiles/create', data).then(r => assertObj(r.data.data, '/profiles/create'));
}

// updateProfile — POST with JSON body.
export function updateProfile(id, data) {
   return axios.post(`/profiles/${encodeURIComponent(id)}/update`, data).then(r => assertObj(r.data.data, `/profiles/${id}/update`));
}

export function removeProfile(id) {
   return axios.get(`/profiles/${encodeURIComponent(id)}/remove`).then(r => assertObj(r.data.data, `/profiles/${id}/remove`));
}

export function renameProfile(id, newName) {
   return axios.get(`/profiles/${encodeURIComponent(id)}/rename`, {
      params: { new_name: newName }
   }).then(r => assertObj(r.data.data, `/profiles/${id}/rename`));
}

// ---------------------------------------------------------------------------
// Host resource suggestions (runtimes, networks, IDEs, auth modes)
// ---------------------------------------------------------------------------

export function getResources() {
   return axios.get('/resources').then(r => assertObj(r.data.data, '/resources'));
}
