<template>
   <div class="user-detail">

      <!-- Header -->
      <div class="detail-header">
         <h5 class="detail-title">
            {{ isNew ? 'New user' : (selfEdit ? 'My account' : username) }}
         </h5>
         <div class="detail-actions" v-if="!isEditMode && !isNew">
            <b-button variant="outline-primary" size="sm" @click="startEdit">Edit</b-button>
            <b-button
               v-if="!selfEdit && canDelete"
               variant="outline-danger"
               size="sm"
               @click="$bvModal.show('confirm-modal-user-' + username)"
            >Delete</b-button>
         </div>
      </div>

      <b-form @submit.prevent="save">

         <!-- username — only editable when creating a new user -->
         <b-form-group label="Username" label-cols="3" v-if="!selfEdit">
            <b-form-input
               v-model="form.username"
               :readonly="!isNew"
               :plaintext="!isNew"
               :state="usernameState"
               placeholder="alphanumeric, hyphens, underscores"
               trim
            />
            <b-form-invalid-feedback>
               Username must contain only letters, digits, hyphens and underscores.
            </b-form-invalid-feedback>
         </b-form-group>

         <!-- name -->
         <b-form-group label="Name" label-cols="3">
            <b-form-input
               v-model="form.name"
               :readonly="!isEditMode && !isNew"
               :plaintext="!isEditMode && !isNew"
               placeholder="Display name"
               trim
            />
         </b-form-group>

         <!-- email -->
         <b-form-group label="Email" label-cols="3">
            <b-form-input
               v-model="form.email"
               type="email"
               :readonly="!isEditMode && !isNew"
               :plaintext="!isEditMode && !isNew"
               placeholder="user@example.com"
               trim
            />
         </b-form-group>

         <!-- role — not shown in selfEdit mode -->
         <b-form-group label="Role" label-cols="3" v-if="!selfEdit">
            <b-form-select
               v-model="form.role"
               :disabled="!isEditMode && !isNew"
               :options="roleOptions"
            />
         </b-form-group>

         <!-- password — only shown for admin user management -->
         <b-form-group label="Password" label-cols="3" v-if="!selfEdit">
            <b-form-input
               v-model="form.password"
               type="password"
               :readonly="!isEditMode && !isNew"
               :plaintext="!isEditMode && !isNew"
               :placeholder="isNew ? 'Leave blank for no password' : 'Leave blank to keep unchanged'"
               autocomplete="new-password"
            />
         </b-form-group>

         <!-- GitHub token -->
         <b-form-group label="GitHub token" label-cols="3">
            <!-- Edit / new mode: show input with show/hide toggle -->
            <b-input-group v-if="isEditMode || isNew">
               <b-form-input
                  v-model="form.gh_token"
                  :type="showToken ? 'text' : 'password'"
                  :placeholder="form.gh_token_is_set ? 'Enter new token to replace existing, or leave blank to keep' : 'ghp_…'"
                  autocomplete="off"
               />
               <b-input-group-append>
                  <b-button variant="outline-secondary" size="sm" @click="showToken = !showToken">
                     {{ showToken ? 'Hide' : 'Reveal' }}
                  </b-button>
               </b-input-group-append>
            </b-input-group>
            <!-- View mode: disabled input; placeholder reflects token status -->
            <b-form-input
               v-else
               disabled
               :placeholder="form.gh_token_masked || ''"
            />
         </b-form-group>

         <!-- Permissions — not shown in selfEdit mode -->
         <b-form-group label="Permissions" label-cols="3" v-if="!selfEdit">
            <PermissionsEditor
               :permissions="form.permissions"
               :role-permissions="rolePermissions"
               :perm-default="rolePermDefault"
               :allow-inherit="true"
               :readonly="!isEditMode && !isNew"
               @update:permissions="form.permissions = $event"
            />
         </b-form-group>

         <!-- Resources — not shown in selfEdit mode -->
         <b-form-group label="Resources" label-cols="3" v-if="!selfEdit">
            <ResourcesEditor
               :resources="form.resources"
               :readonly="!isEditMode && !isNew"
               @update:resources="form.resources = $event"
            />
         </b-form-group>

         <!-- SSH keys -->
         <b-form-group label="SSH keys" label-cols="3">
            <SshEditor
               :ssh="form.ssh"
               :readonly="!isEditMode && !isNew"
               @input="form.ssh = $event"
            />
         </b-form-group>

         <!-- Save / Cancel buttons -->
         <div v-if="isEditMode || isNew" class="detail-form-actions">
            <b-button type="submit" variant="primary" size="sm" :disabled="saving">
               {{ saving ? 'Saving…' : 'Save' }}
            </b-button>
            <b-button variant="outline-secondary" size="sm" :disabled="saving" @click="cancel">
               Cancel
            </b-button>
            <span v-if="saveError" class="text-danger ml-2 save-error">{{ saveError }}</span>
         </div>

      </b-form>

      <!-- Delete confirmation -->
      <ConfirmModal
         v-if="!selfEdit && !isNew"
         :id="'user-' + username"
         :title="'Delete user ' + username"
         :message="'Are you sure you want to delete user \'' + username + '\'? This cannot be undone.'"
         @confirm="deleteUser"
      />

   </div>
</template>

<script>
   import { mapState, mapGetters } from 'vuex';
   import PermissionsEditor from '@/components/admin/PermissionsEditor';
   import ResourcesEditor   from '@/components/admin/ResourcesEditor';
   import SshEditor         from '@/components/admin/SshEditor';
   import ConfirmModal      from '@/components/shared/ConfirmModal';
   import { getSelf }       from '@/services/admin';

   const DEFAULT_RESOURCES = () => ({
      profiles: ['*'],
      runtimes: ['*'],
      networks: ['*'],
      auth:     ['*'],
      images:   ['*'],
      IDEs:     ['*'],
   });

   const EMPTY_FORM = () => ({
      username:        '',
      name:            '',
      email:           '',
      role:            'user',
      password:        '',
      gh_token:        '',        // new token value (empty = not changing)
      gh_token_is_set: false,     // true when server returned a masked token
      gh_token_masked: '',        // masked token value from server (e.g. ghp_****abcd)
      permissions:     {},
      resources:       DEFAULT_RESOURCES(),
      ssh:             {},
   });

   export default {
      name: 'UserDetail',
      components: { PermissionsEditor, ResourcesEditor, SshEditor, ConfirmModal },

      props: {
         username: {
            type: String,
            default: null,
         },
         selfEdit: {
            type: Boolean,
            default: false,
         },
      },

      data() {
         // Pre-populate name/email from bootstrap data so the account view
         // shows real content instantly without waiting for getSelf().
         const initial = EMPTY_FORM();
         if (this.selfEdit) {
            const u = window.dockside && window.dockside.user;
            if (u) {
               initial.username = u.username || '';
               initial.name     = u.name     || '';
               initial.email    = u.email    || '';
            }
         }
         return {
            form:          initial,
            showToken:     false,
            saving:        false,
            saveError:     null,
            localEditMode: false,  // view/edit toggle used for selfEdit
            savedForm:     null,   // snapshot of form taken when entering edit mode
            sshLoaded:     false,  // true once SSH data has been fetched from server
         };
      },

      computed: {
         ...mapState('admin', ['users', 'roles', 'selected']),
         ...mapGetters('admin', ['isNewItem', 'roleNames']),

         isNew() {
            return !this.username;
         },

         // selfEdit uses local state; admin view uses Vuex mode + isNew.
         isEditMode() {
            if (this.selfEdit) return this.localEditMode;
            return this.$store.getters['admin/isEditMode'] || this.isNew;
         },

         canDelete() {
            const currentUser = window.dockside && window.dockside.user && window.dockside.user.username;
            return this.username && this.username !== currentUser;
         },

         roleOptions() {
            return this.roleNames.map(n => ({ value: n, text: n }));
         },

         usernameState() {
            if (!this.form.username) return null;
            return /^[A-Za-z0-9_-]+$/.test(this.form.username) ? true : false;
         },

         currentUserRecord() {
            return this.users.find(u => u.username === this.username) || null;
         },

         rolePermissions() {
            const role = this.roles.find(r => r.name === this.form.role);
            return (role && role.permissions) || {};
         },

         // Effective default for permissions not explicitly set by the user's role.
         // Admin role grants everything by default; other roles deny by default.
         rolePermDefault() {
            return this.form.role === 'admin' ? '1' : '0';
         },

         hasSshChanges() {
            const ssh = this.form.ssh || {};
            return Object.keys(ssh).length > 0;
         },
      },

      created() {
         if (this.selfEdit) {
            // Populate from store synchronously (no flash) if data is already loaded.
            if (this.currentUserRecord) this.populateForm(this.currentUserRecord);
            // Always refresh from server — may include sensitive fields (gh_token, ssh).
            getSelf().then(record => {
               if (!this.localEditMode) this.populateForm(record);
            }).catch(() => {});
         } else if (!this.isNew && this.currentUserRecord) {
            this.populateForm(this.currentUserRecord);
         }
      },

      watch: {
         // Re-sync view data when store updates (e.g. after save or fetchAll).
         // Never re-sync while the user is actively editing.
         currentUserRecord(r) {
            if (r && !this.isEditMode) this.populateForm(r);
         },
      },

      methods: {
         populateForm(record) {
            const maskedToken = record.gh_token || '';
            const tokenIsSet  = !!maskedToken;
            this.form = {
               username:        record.username    || '',
               name:            record.name        || '',
               email:           record.email       || '',
               role:            record.role        || 'user',
               password:        '',
               gh_token:        '',
               gh_token_is_set: tokenIsSet,
               gh_token_masked: maskedToken,
               permissions:     record.permissions ? { ...record.permissions } : {},
               resources:       record.resources   ? { ...record.resources }   : {},
               ssh:             record.ssh         ? { ...record.ssh }         : {},
            };
            if (record.ssh !== undefined) this.sshLoaded = true;
         },

         startEdit() {
            if (this.selfEdit) {
               // Snapshot current form so cancel() can revert cleanly.
               this.savedForm    = JSON.parse(JSON.stringify(this.form));
               this.showToken    = false;
               this.localEditMode = true;
            } else {
               this.$store.commit('admin/setSelectedMode', 'edit');
            }
         },

         cancel() {
            if (this.isNew) {
               this.$router.push('/admin/users').catch(() => {});
               this.$store.commit('admin/clearSelected');
            } else if (this.selfEdit) {
               this.localEditMode = false;
               // Restore the pre-edit snapshot.
               if (this.savedForm) {
                  this.form      = this.savedForm;
                  this.savedForm = null;
               } else if (this.currentUserRecord) {
                  this.populateForm(this.currentUserRecord);
               }
            } else {
               this.$store.commit('admin/setSelectedMode', 'view');
               if (this.currentUserRecord) this.populateForm(this.currentUserRecord);
            }
         },

         async save() {
            this.saving    = true;
            this.saveError = null;
            if (!this.selfEdit && !this.form.role) {
               this.saveError = 'A role is required.';
               this.saving = false;
               return;
            }
            try {
               const payload = {
                  name:  this.form.name,
                  email: this.form.email,
               };
               // Include SSH when creating a user, when the existing SSH block was
               // fetched, or when the editor contains newly added SSH data.
               // This still avoids wiping unknown SSH data after a failed fetch.
               if (this.isNew || this.sshLoaded || this.hasSshChanges) payload.ssh = this.form.ssh;
               // Only send gh_token when the user has typed a new value.
               if (this.form.gh_token) payload.gh_token = this.form.gh_token;

               if (!this.selfEdit) {
                  payload.role        = this.form.role;
                  payload.permissions = this.form.permissions;
                  payload.resources   = this.form.resources;
                  if (this.form.password) payload.password = this.form.password;
               }

               if (this.selfEdit) {
                  await this.$store.dispatch('admin/updateSelf', payload);
                  this.savedForm     = null;
                  this.localEditMode = false;
                  // currentUserRecord watcher fires after store update and re-populates form.
               } else if (this.isNew) {
                  payload.username = this.form.username;
                  const record = await this.$store.dispatch('admin/createUser', payload);
                  this.$router.push(`/admin/users/${encodeURIComponent(record.username)}`).catch(() => {});
                  this.$store.commit('admin/setSelected', { type: 'user', id: record.username, mode: 'view' });
                  return;
               } else {
                  await this.$store.dispatch('admin/updateUser', { username: this.username, data: payload });
                  this.$store.commit('admin/setSelectedMode', 'view');
               }
            } catch (e) {
               this.saveError = e.response ? (e.response.data && e.response.data.msg) || e.message : e.message;
            } finally {
               this.saving = false;
            }
         },

         async deleteUser() {
            try {
               await this.$store.dispatch('admin/removeUser', this.username);
               this.$router.push('/admin/users').catch(() => {});
               this.$store.commit('admin/clearSelected');
            } catch (e) {
               this.saveError = e.message;
            }
         },
      },
   };
</script>

<style lang="scss" scoped>
   .user-detail {
      padding-top: 8px;
   }

   .detail-header {
      display: flex;
      justify-content: space-between;
      align-items: center;
      margin-bottom: 16px;
      border-bottom: 1px solid #eee;
      padding-bottom: 8px;
   }

   .detail-title {
      margin: 0;
      font-size: 1.1rem;
   }

   .detail-actions {
      display: flex;
      gap: 6px;
   }

   .detail-form-actions {
      display: flex;
      align-items: center;
      gap: 8px;
      margin-top: 16px;
      padding-top: 12px;
      border-top: 1px solid #eee;
   }

   .save-error {
      font-size: 0.85rem;
   }
</style>
