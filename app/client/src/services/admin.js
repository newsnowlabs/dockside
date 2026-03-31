// Admin API service — users, roles, profiles, and self-service account editing.
// Follows the same axios pattern as services/container.js.
// Mutation endpoints (create/update) for users and profiles use POST with a
// JSON body so large payloads (e.g. profile JSON) don't hit URL length limits.
// Role mutations remain GET/query-string because role records are small.

import axios from 'axios';

// ---------------------------------------------------------------------------
// Users
// ---------------------------------------------------------------------------

export function listUsers() {
   return axios.get('/users').then(r => r.data.data);
}

export function getUser(username, sensitive = false) {
   const params = sensitive ? { sensitive: 1 } : {};
   return axios.get(`/users/${encodeURIComponent(username)}`, { params }).then(r => r.data.data);
}

export function createUser(data) {
   return axios.post('/users/create', data).then(r => r.data.data);
}

export function updateUser(username, data) {
   return axios.post(`/users/${encodeURIComponent(username)}/update`, data).then(r => r.data.data);
}

export function removeUser(username) {
   return axios.get(`/users/${encodeURIComponent(username)}/remove`).then(r => r.data.data);
}

// ---------------------------------------------------------------------------
// Roles
// ---------------------------------------------------------------------------

export function listRoles() {
   return axios.get('/roles').then(r => r.data.data);
}

export function getRole(name) {
   return axios.get(`/roles/${encodeURIComponent(name)}`).then(r => r.data.data);
}

export function createRole(data) {
   return axios.post('/roles/create', data).then(r => r.data.data);
}

export function updateRole(name, data) {
   return axios.post(`/roles/${encodeURIComponent(name)}/update`, data).then(r => r.data.data);
}

export function removeRole(name) {
   return axios.get(`/roles/${encodeURIComponent(name)}/remove`).then(r => r.data.data);
}

// ---------------------------------------------------------------------------
// Profiles
// ---------------------------------------------------------------------------

export function listProfiles() {
   return axios.get('/profiles').then(r => r.data.data);
}

export function getProfile(id) {
   return axios.get(`/profiles/${encodeURIComponent(id)}`).then(r => r.data.data);
}

/**
 * createProfile — POST with JSON body.
 * `data` must include `id` plus the profile body fields.
 * The caller should pass `_json` as a JSON-stringified version of the profile
 * body, alongside the simple scalar fields.
 */
export function createProfile(data) {
   return axios.post('/profiles/create', data).then(r => r.data.data);
}

/**
 * updateProfile — POST with JSON body.
 */
export function updateProfile(id, data) {
   return axios.post(`/profiles/${encodeURIComponent(id)}/update`, data).then(r => r.data.data);
}

export function removeProfile(id) {
   return axios.get(`/profiles/${encodeURIComponent(id)}/remove`).then(r => r.data.data);
}

export function renameProfile(id, newName) {
   return axios.get(`/profiles/${encodeURIComponent(id)}/rename`, {
      params: { new_name: newName }
   }).then(r => r.data.data);
}

// ---------------------------------------------------------------------------
// Host resource suggestions (runtimes, networks, IDEs, auth modes)
// ---------------------------------------------------------------------------

export function getResources() {
   return axios.get('/resources').then(r => r.data.data);
}
