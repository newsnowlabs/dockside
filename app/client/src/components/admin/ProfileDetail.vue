<template>
   <div class="profile-detail">

      <!-- Header -->
      <div class="detail-header">
         <div class="detail-title-wrap">
            <h5 class="detail-title">
               {{ isNew ? 'New profile' : (form.name || profileId) }}
            </h5>
            <span v-if="!isNew" class="profile-active-badge" :class="form.active ? 'badge-active' : 'badge-inactive'">
               {{ form.active ? 'active' : 'inactive' }}
            </span>
         </div>
         <div class="detail-actions" v-if="!isEditMode && !isNew">
            <b-button variant="outline-primary" size="sm" @click="startEdit">Edit</b-button>
            <b-button
               variant="outline-secondary"
               size="sm"
               :disabled="hasUnsavedEdits"
               :title="hasUnsavedEdits ? 'Save or cancel edits before renaming.' : 'Rename profile ID'"
               @click="startRename"
            >Rename</b-button>
            <b-button
               variant="outline-danger"
               size="sm"
               @click="$bvModal.show('confirm-modal-profile-' + profileId)"
            >Delete</b-button>
         </div>
      </div>

      <!-- Rename inline form -->
      <div v-if="isRenaming" class="rename-bar">
         <label class="rename-label">New ID:</label>
         <b-form-input
            v-model="renameValue"
            :state="renameState"
            size="sm"
            trim
            class="rename-input"
            @keyup.enter="commitRename"
            @keyup.escape="cancelRename"
         />
         <b-button variant="primary" size="sm" :disabled="renameState !== true || renaming" @click="commitRename">
            {{ renaming ? 'Renaming…' : 'Apply' }}
         </b-button>
         <b-button variant="outline-secondary" size="sm" @click="cancelRename">Cancel</b-button>
         <span v-if="renameError" class="text-danger ml-2 save-error">{{ renameError }}</span>
      </div>

      <b-form @submit.prevent="save">

         <!-- id — read-only once created -->
         <b-form-group label="ID" label-cols="3" v-if="isNew">
            <b-form-input
               v-model="form.id"
               :state="idState"
               placeholder="letters, digits, dots, hyphens, underscores"
               trim
            />
            <b-form-invalid-feedback>
               ID must start with a letter or digit and contain only letters, digits, dots, hyphens and underscores.
               Reserved names (create, update, remove, rename) are not allowed.
            </b-form-invalid-feedback>
         </b-form-group>
         <b-form-group label="ID" label-cols="3" v-else>
            <b-form-input :value="profileId" readonly plaintext />
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

         <!-- description -->
         <b-form-group label="Description" label-cols="3">
            <b-form-input
               v-model="form.description"
               :readonly="!isEditMode && !isNew"
               :plaintext="!isEditMode && !isNew"
               placeholder="Brief description"
               trim
            />
         </b-form-group>

         <!-- active -->
         <b-form-group label="Active" label-cols="3">
            <b-form-checkbox
               v-model="form.active"
               :disabled="!isEditMode && !isNew"
               switch
            >
               {{ form.active ? 'Active (available to users)' : 'Inactive (hidden from users)' }}
            </b-form-checkbox>
         </b-form-group>

         <!-- version — read-only display -->
         <b-form-group label="Version" label-cols="3" v-if="!isNew">
            <b-form-input :value="form.version" readonly plaintext />
         </b-form-group>

         <!-- JSON body editor -->
         <b-form-group label="Profile body" label-cols="3">
            <div v-if="!isEditMode && !isNew" class="json-readonly-hint">
               Switch to Edit mode to modify the profile body.
            </div>
            <JsonEditor
               v-else
               :value="profileBody"
               mode="tree"
               @input="profileBody = $event"
            />
         </b-form-group>

         <!-- Save / Cancel -->
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
         v-if="!isNew"
         :id="'profile-' + profileId"
         :title="'Delete profile ' + profileId"
         :message="'Are you sure you want to delete profile \'' + profileId + '\'?'"
         @confirm="deleteProfile"
      />

   </div>
</template>

<script>
   import { mapState, mapGetters } from 'vuex';
   import JsonEditor   from '@/components/shared/JsonEditor';
   import ConfirmModal from '@/components/shared/ConfirmModal';

   // These keys are managed as structured fields; everything else goes in the JSON editor.
   const STRUCTURED_KEYS = ['id', 'name', 'description', 'active', 'version'];

   const RESERVED_NAMES = new Set(['create', 'update', 'remove', 'rename']);

   const EMPTY_FORM = () => ({
      id:          '',
      name:        '',
      description: '',
      active:      false,
      version:     null,
   });

   export default {
      name: 'ProfileDetail',
      components: { JsonEditor, ConfirmModal },

      props: {
         profileId: {
            type: String,
            default: null,
         },
      },

      data() {
         return {
            form:         EMPTY_FORM(),
            profileBody:  {},   // the profile JSON minus structured keys
            saving:       false,
            saveError:    null,
            isRenaming:   false,
            renameValue:  '',
            renaming:     false,
            renameError:  null,
            origForm:     null, // snapshot for unsaved-edits detection
            origBody:     null,
         };
      },

      computed: {
         ...mapState('admin', ['profiles', 'selected']),
         ...mapGetters('admin', ['isEditMode']),

         isNew() {
            return !this.profileId;
         },

         isEditMode() {
            return this.$store.getters['admin/isEditMode'] || this.isNew;
         },

         idState() {
            if (!this.form.id) return null;
            return /^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(this.form.id) &&
                   !RESERVED_NAMES.has(this.form.id) ? true : false;
         },

         renameState() {
            if (!this.renameValue) return null;
            return /^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(this.renameValue) &&
                   !RESERVED_NAMES.has(this.renameValue) &&
                   this.renameValue !== this.profileId ? true : false;
         },

         currentProfileRecord() {
            return this.profiles.find(p => p.id === this.profileId) || null;
         },

         hasUnsavedEdits() {
            if (!this.origForm) return false;
            return JSON.stringify(this.form) !== this.origForm ||
                   JSON.stringify(this.profileBody) !== this.origBody;
         },
      },

      created() {
         if (!this.isNew && this.currentProfileRecord) {
            this.populateForm(this.currentProfileRecord);
         }
      },

      watch: {
         currentProfileRecord(r) {
            if (r && !this.isEditMode) this.populateForm(r);
         },
      },

      methods: {
         populateForm(record) {
            this.form = {
               id:          record.id          || '',
               name:        record.name        || '',
               description: record.description || '',
               active:      !!record.active,
               version:     record.version     || null,
            };
            // Extract body: everything except structured keys
            const body = {};
            for (const [k, v] of Object.entries(record)) {
               if (!STRUCTURED_KEYS.includes(k)) body[k] = v;
            }
            this.profileBody = body;
            // Snapshot for unsaved-edits detection
            this.origForm = JSON.stringify(this.form);
            this.origBody = JSON.stringify(this.profileBody);
         },

         startEdit() {
            this.$store.commit('admin/setSelectedMode', 'edit');
            this.origForm = JSON.stringify(this.form);
            this.origBody = JSON.stringify(this.profileBody);
         },

         cancel() {
            if (this.isNew) {
               this.$router.push('/admin/profiles').catch(() => {});
               this.$store.commit('admin/clearSelected');
            } else {
               this.$store.commit('admin/setSelectedMode', 'view');
               if (this.currentProfileRecord) this.populateForm(this.currentProfileRecord);
            }
         },

         buildPayload() {
            // Merge structured fields into the body for the _json parameter
            const fullProfile = {
               ...this.profileBody,
               name:        this.form.name,
               description: this.form.description,
               active:      this.form.active,
            };
            if (this.form.version) fullProfile.version = this.form.version;
            return {
               id:    this.form.id || this.profileId,
               name:  this.form.name,
               active: this.form.active ? '1' : '0',
               _json: JSON.stringify(fullProfile),
            };
         },

         async save() {
            this.saving    = true;
            this.saveError = null;
            try {
               const payload = this.buildPayload();

               if (this.isNew) {
                  const record = await this.$store.dispatch('admin/createProfile', payload);
                  this.$router.push(`/admin/profiles/${encodeURIComponent(record.id)}`).catch(() => {});
                  this.$store.commit('admin/setSelected', { type: 'profile', id: record.id, mode: 'view' });
                  return;
               } else {
                  await this.$store.dispatch('admin/updateProfile', { id: this.profileId, data: payload });
                  this.$store.commit('admin/setSelectedMode', 'view');
                  this.origForm = JSON.stringify(this.form);
                  this.origBody = JSON.stringify(this.profileBody);
               }
            } catch (e) {
               this.saveError = e.response ? (e.response.data && e.response.data.msg) || e.message : e.message;
            } finally {
               this.saving = false;
            }
         },

         startRename() {
            this.renameValue = this.profileId;
            this.renameError = null;
            this.isRenaming  = true;
         },

         cancelRename() {
            this.isRenaming  = false;
            this.renameValue = '';
            this.renameError = null;
         },

         async commitRename() {
            if (this.renameState !== true) return;
            this.renaming    = true;
            this.renameError = null;
            try {
               const result = await this.$store.dispatch('admin/renameProfile', {
                  id: this.profileId, newName: this.renameValue,
               });
               this.$router.push(`/admin/profiles/${encodeURIComponent(result.id)}`).catch(() => {});
               this.$store.commit('admin/setSelected', { type: 'profile', id: result.id, mode: 'view' });
               this.isRenaming = false;
            } catch (e) {
               this.renameError = e.response ? (e.response.data && e.response.data.msg) || e.message : e.message;
            } finally {
               this.renaming = false;
            }
         },

         async deleteProfile() {
            try {
               await this.$store.dispatch('admin/removeProfile', this.profileId);
               this.$router.push('/admin/profiles').catch(() => {});
               this.$store.commit('admin/clearSelected');
            } catch (e) {
               this.saveError = e.message;
            }
         },
      },
   };
</script>

<style lang="scss" scoped>
   .profile-detail {
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

   .detail-title-wrap {
      display: flex;
      align-items: center;
      gap: 10px;
   }

   .detail-title {
      margin: 0;
      font-size: 1.1rem;
   }

   .profile-active-badge {
      font-size: 0.72rem;
      font-weight: 600;
      padding: 2px 8px;
      border-radius: 10px;

      &.badge-active   { background: #d4edda; color: #155724; }
      &.badge-inactive { background: #e2e3e5; color: #383d41; }
   }

   .detail-actions {
      display: flex;
      gap: 6px;
   }

   .rename-bar {
      display: flex;
      align-items: center;
      gap: 8px;
      margin-bottom: 16px;
      padding: 8px 10px;
      background: #f8f9fa;
      border: 1px solid #dee2e6;
      border-radius: 4px;
   }

   .rename-label {
      margin: 0;
      font-weight: 600;
      font-size: 0.85rem;
      white-space: nowrap;
   }

   .rename-input {
      width: 220px;
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

   .json-readonly-hint {
      color: #888;
      font-style: italic;
      font-size: 0.85rem;
      padding: 6px 0;
   }
</style>
