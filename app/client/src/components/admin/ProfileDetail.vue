<template>
   <div class="profile-detail">

      <!-- Unknown profile id: the list has loaded and there is no such record.
           Show only this message — never the editable form, action buttons,
           JSON editor or delete modal — so a bad id can't masquerade as a record. -->
      <v-alert v-if="profileNotFound" type="error" variant="tonal">
         Profile '{{ profileId }}' not found.
      </v-alert>

      <!-- Valid record or the create ('new') flow. While the list is still loading
           for an existing id (not new, no record yet, not yet profilesLoaded) we
           render nothing here rather than an empty form. -->
      <template v-else-if="isNew || currentProfileRecord">

      <!-- Header -->
      <div class="detail-header">
         <div class="detail-title-wrap">
            <h5 class="detail-title">
               {{ isNew ? 'New profile' : (form.name || profileId) }}
            </h5>
            <v-chip v-if="!isNew" size="small" :color="form.active ? 'success' : undefined">
               {{ form.active ? 'active' : 'inactive' }}
            </v-chip>
         </div>
         <div class="detail-actions" v-if="!isEditMode && !isNew">
            <v-btn variant="outlined" size="small" @click="startEdit">Edit</v-btn>
            <v-btn
               variant="outlined" size="small"
               :disabled="hasUnsavedEdits"
               :title="hasUnsavedEdits ? 'Save or cancel edits before renaming.' : 'Rename profile ID'"
               @click="startRename"
            >Rename</v-btn>
            <v-btn
               variant="outlined" color="error" size="small"
               @click="showDeleteConfirm = true"
            >Delete</v-btn>
         </div>
      </div>

      <!-- Rename inline form -->
      <div v-if="isRenaming" class="rename-bar">
         <v-text-field
            v-model="renameValue"
            label="New ID"
            :error="renameState === false"
            density="compact"
            variant="outlined"
            hide-details
            class="rename-input"
            @keyup.enter="commitRename"
            @keyup.escape="cancelRename"
         />
         <v-btn color="primary" variant="flat" size="small" :disabled="renameState !== true || renaming" @click="commitRename">
            {{ renaming ? 'Renaming…' : 'Apply' }}
         </v-btn>
         <v-btn variant="outlined" size="small" @click="cancelRename">Cancel</v-btn>
         <span v-if="renameError" class="save-error">{{ renameError }}</span>
      </div>

      <form @submit.prevent="save">

         <!-- id — read-only once created -->
         <v-text-field
            v-if="isNew"
            v-model="form.id"
            label="ID"
            :error="idState === false"
            :error-messages="idState === false ? [idErrorText] : []"
            placeholder="letters, digits, dots, hyphens, underscores"
            density="compact"
            variant="outlined"
            class="mb-2"
         />
         <v-text-field
            v-else
            label="ID"
            :model-value="profileId"
            readonly
            variant="plain"
            density="compact"
            class="mb-2"
         />

         <!-- name -->
         <v-text-field
            v-model="form.name"
            label="Name"
            :readonly="!isEditMode && !isNew"
            :variant="(!isEditMode && !isNew) ? 'plain' : 'outlined'"
            placeholder="Display name"
            density="compact"
            class="mb-2"
         />

         <!-- description -->
         <v-text-field
            v-model="form.description"
            label="Description"
            :readonly="!isEditMode && !isNew"
            :variant="(!isEditMode && !isNew) ? 'plain' : 'outlined'"
            placeholder="Brief description"
            density="compact"
            class="mb-2"
         />

         <!-- active -->
         <v-switch
            v-model="form.active"
            :disabled="!isEditMode && !isNew"
            :label="form.active ? 'Active (available to users)' : 'Inactive (hidden from users)'"
            color="primary"
            density="compact"
            hide-details
            class="mb-2"
         />

         <!-- version — read-only display -->
         <v-text-field
            v-if="!isNew"
            label="Version"
            :model-value="form.version"
            readonly
            variant="plain"
            density="compact"
            class="mb-2"
         />

         <!-- JSON body — tree view when viewing (read-only; easier to scan), text mode
              when editing or creating (raw JSON is the natural edit surface). Bound to the
              edit state so the mode follows view↔edit; while editing the user can still
              switch modes via the editor's own control. -->
         <div class="form-row">
            <div class="form-row-label">Profile body</div>
            <JsonEditor
               :value="profileBody"
               :readonly="!isEditMode && !isNew"
               :mode="(isEditMode || isNew) ? 'text' : 'tree'"
               @input="profileBody = $event"
            />
         </div>

         <!-- Save / Cancel -->
         <div v-if="isEditMode || isNew" class="detail-form-actions">
            <v-btn type="submit" color="primary" size="small" :disabled="saving">
               {{ saving ? 'Saving…' : 'Save' }}
            </v-btn>
            <v-btn variant="outlined" size="small" :disabled="saving" @click="cancel">
               Cancel
            </v-btn>
            <span v-if="saveError" class="save-error">{{ saveError }}</span>
         </div>

      </form>

      <!-- Delete confirmation -->
      <ConfirmModal
         v-if="!isNew"
         v-model="showDeleteConfirm"
         :title="'Delete profile ' + profileId"
         :message="'Are you sure you want to delete profile \'' + profileId + '\'?'"
         @confirm="deleteProfile"
      />

      </template>

   </div>
</template>

<script>
import { defineComponent } from 'vue';

import { mapState } from 'vuex';
import JsonEditor   from '@/components/shared/JsonEditor';
import ConfirmModal from '@/components/shared/ConfirmModal';

// Keys that are surfaced as individual form fields (id, name, description, active,
// version).  All other keys from the profile record are passed to the JSON editor
// as the 'body' so the admin can edit them in a structured tree view.
const STRUCTURED_KEYS = ['id', 'name', 'description', 'active', 'version'];

// Mirror the server's reserved profile identifiers (Profile::Manage %RESERVED_NAMES):
// the route verbs plus 'new', the create-form sentinel. 'new' must be included or the
// client accepts an id the server then rejects.
const RESERVED_NAMES = new Set(['create', 'update', 'remove', 'rename', 'new']);

const EMPTY_FORM = () => ({
   id:          '',
   name:        '',
   description: '',
   active:      false,
   version:     null,
});

// Template body shown in the JSON editor when creating a new profile.
// Lists every supported top-level property at the current schema version (4)
// with sensible empty defaults so the user can see what's available.
const PROFILE_TEMPLATE_BODY = {
   version:          4,
   routers:          [],
   runtimes:         [],
   networks:         [],
   images:           [],
   unixusers:        [],
   ssh:              false,
   IDEs:             [],
   mountIDE:         false,
   imagePathsFilter: [],
   mounts:           {},
   runDockerInit:    false,
   dockerArgs:       [],
   command:          [],
   entrypoint:       [],
   metadata:         {},
   lxcfs:            false,
   security:         {},
   gitURLs:          [],
   options:          [],
};

export default defineComponent({
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
        form:              EMPTY_FORM(),
        profileBody:       this.profileId ? {} : { ...PROFILE_TEMPLATE_BODY },
        saving:            false,
        saveError:         null,
        isRenaming:        false,
        renameValue:       '',
        renaming:          false,
        renameError:       null,
        origForm:          null, // snapshot for unsaved-edits detection
        origBody:          null,
        showDeleteConfirm: false,
     };
  },

  computed: {
     ...mapState('admin', ['profiles', 'selected', 'profilesLoaded']),

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

     idErrorText() {
        return "ID must start with a letter or digit and contain only letters, digits, dots, hyphens and underscores. Reserved names (create, update, remove, rename) are not allowed.";
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

     // True once the list has loaded and confirmed there is no profile with
     // this id (and we're not on the create flow). Gated on profilesLoaded so
     // we don't flash "not found" while the list is still being fetched.
     profileNotFound() {
        return !this.isNew && this.profilesLoaded && !this.currentProfileRecord;
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
        // Build the JSON blob (_json) by merging structured fields back into
        // the body.  The server's createProfile/updateProfile will decode _json
        // as the authoritative profile body, so it must be complete.
        //
        // JsonEditor may hand back the body as a string (its documented contract,
        // e.g. when edited in code mode), so coerce to an object before spreading —
        // otherwise `{...string}` would explode into character-indexed keys and the
        // server would reject the record.  Invalid JSON surfaces as a clean error
        // (caught by save()) rather than a corrupt payload.
        let body = this.profileBody;
        if (typeof body === 'string') {
           try {
              body = JSON.parse(body);
           } catch (e) {
              throw new Error(`Profile body is not valid JSON: ${e.message}`);
           }
        }
        if (!body || typeof body !== 'object' || Array.isArray(body)) {
           throw new Error('Profile body must be a JSON object');
        }
        const fullProfile = {
           ...body,
           name:        this.form.name,
           description: this.form.description,
           active:      this.form.active,  // boolean (JS) → JSON boolean in _json
        };
        if (this.form.version) fullProfile.version = this.form.version;
        return {
           id:    this.form.id || this.profileId,
           name:  this.form.name,
           // active is carried inside _json as a JSON boolean; the server's
           // coerce step (active ? JSON::true : JSON::false) handles it correctly.
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
});
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

   .rename-input {
      width: 220px;
      flex: 0 0 auto;
   }

   .form-row {
      margin-bottom: 16px;
   }

   .form-row-label {
      font-size: 0.75rem;
      font-weight: 600;
      text-transform: uppercase;
      letter-spacing: 0.05em;
      color: #495057;
      margin-bottom: 4px;
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
      color: rgb(var(--v-theme-error));
      margin-left: 8px;
   }
</style>
