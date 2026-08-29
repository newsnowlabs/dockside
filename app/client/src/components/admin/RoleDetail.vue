<template>
   <div class="role-detail">

      <!-- Requested role does not exist (server 404) -->
      <v-alert v-if="roleNotFound" type="error" variant="tonal">
         Role '{{ roleName }}' not found.
      </v-alert>

      <template v-else-if="showForm">

      <!-- Header -->
      <div class="detail-header">
         <h5 class="detail-title">
            {{ isNew ? 'New role' : roleName }}
         </h5>
         <div class="detail-actions" v-if="!isEditMode && !isNew">
            <v-btn variant="outlined" size="small" @click="startEdit">Edit</v-btn>
            <v-btn
               variant="outlined" color="error" size="small"
               :disabled="deleteDisabled"
               :title="deleteDisabled ? 'Role is assigned to one or more users and cannot be deleted.' : ''"
               @click="showDeleteConfirm = true"
            >Delete</v-btn>
         </div>
      </div>

      <form @submit.prevent="save">

         <!-- name — only editable when creating -->
         <v-text-field
            v-model="form.name"
            label="Name"
            :readonly="!isNew"
            :variant="isNew ? 'outlined' : 'plain'"
            :error="nameState === false"
            :error-messages="nameState === false ? [nameErrorText] : []"
            placeholder="alphanumeric, hyphens, underscores"
            density="compact"
        />

         <!-- Permissions -->
         <div class="form-row">
            <div class="form-row-label">Permissions</div>
            <PermissionsEditor
               :permissions="form.permissions"
               :allow-inherit="false"
               :perm-default="form.name === 'admin' ? '1' : '0'"
               :readonly="!isEditMode && !isNew"
               @update:permissions="form.permissions = $event"
            />
         </div>

         <!-- Resources -->
         <div class="form-row">
            <div class="form-row-label">Resources</div>
            <ResourcesEditor
               :resources="form.resources"
               :readonly="!isEditMode && !isNew"
               @update:resources="form.resources = $event"
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
         :title="'Delete role ' + roleName"
         :message="'Are you sure you want to delete role \'' + roleName + '\'? This cannot be undone.'"
         @confirm="deleteRole"
      />

      </template>

   </div>
</template>

<script>
import { defineComponent } from 'vue';

import { mapState } from 'vuex';
import PermissionsEditor from '@/components/admin/PermissionsEditor';
import ResourcesEditor   from '@/components/admin/ResourcesEditor';
import ConfirmModal      from '@/components/shared/ConfirmModal';

const EMPTY_FORM = () => ({
   name:        '',
   permissions: {},
   resources:   {},
});

export default defineComponent({
  name: 'RoleDetail',
  components: { PermissionsEditor, ResourcesEditor, ConfirmModal },

  props: {
     roleName: {
        type: String,
        default: null,
     },
  },

  data() {
     return {
        form:              EMPTY_FORM(),
        saving:            false,
        saveError:         null,
        showDeleteConfirm: false,
     };
  },

  computed: {
     ...mapState('admin', ['roles', 'users', 'selected', 'rolesLoaded']),

     isNew() {
        return !this.roleName;
     },

     // Override the Vuex getter: a role is always in edit mode when it is new
     // (no roleName prop), regardless of the stored admin/selected.mode value.
     isEditMode() {
        return this.$store.getters['admin/isEditMode'] || this.isNew;
     },

     nameState() {
        if (!this.form.name) return null;
        return /^[A-Za-z0-9_-]+$/.test(this.form.name) ? true : false;
     },

     nameErrorText() {
        return 'Role name must contain only letters, digits, hyphens and underscores.';
     },

     currentRoleRecord() {
        return this.roles.find(r => r.name === this.roleName) || null;
     },

     // True once the roles list has loaded and the requested role still does
     // not exist — i.e. a 404 in the server.  Gated on rolesLoaded so we do
     // not flash "not found" while the list is still being fetched.
     roleNotFound() {
        return !this.isNew && this.rolesLoaded && !this.currentRoleRecord;
     },

     // Whether the editable form / actions should render: the create flow,
     // or an existing, resolved record.
     showForm() {
        return this.isNew || !!this.currentRoleRecord;
     },

     // Mirror the server-side guard: prevent deletion of a role that is still
     // assigned to at least one user.  Disabling the button in the UI avoids
     // an error round-trip; the server enforces this independently.
     deleteDisabled() {
        return this.users.some(u => u.role === this.roleName);
     },
  },

  created() {
     if (!this.isNew && this.currentRoleRecord) {
        this.populateForm(this.currentRoleRecord);
     }
  },

  watch: {
     currentRoleRecord(r) {
        if (r && !this.isEditMode) this.populateForm(r);
     },
  },

  methods: {
     populateForm(record) {
        this.form = {
           name:        record.name        || '',
           permissions: record.permissions ? { ...record.permissions } : {},
           resources:   record.resources   ? { ...record.resources }   : {},
        };
     },

     startEdit() {
        this.$store.commit('admin/setSelectedMode', 'edit');
     },

     cancel() {
        if (this.isNew) {
           this.$router.push('/admin/roles').catch(() => {});
           this.$store.commit('admin/clearSelected');
        } else {
           this.$store.commit('admin/setSelectedMode', 'view');
           if (this.currentRoleRecord) this.populateForm(this.currentRoleRecord);
        }
     },

     async save() {
        this.saving    = true;
        this.saveError = null;
        try {
           const payload = {
              name:        this.form.name,
              permissions: this.form.permissions,
              resources:   this.form.resources,
           };

           if (this.isNew) {
              const record = await this.$store.dispatch('admin/createRole', payload);
              this.$router.push(`/admin/roles/${encodeURIComponent(record.name)}`).catch(() => {});
              this.$store.commit('admin/setSelected', { type: 'role', id: record.name, mode: 'view' });
              return;
           } else {
              await this.$store.dispatch('admin/updateRole', { name: this.roleName, data: payload });
              this.$store.commit('admin/setSelectedMode', 'view');
           }
        } catch (e) {
           this.saveError = e.response ? (e.response.data && e.response.data.msg) || e.message : e.message;
        } finally {
           this.saving = false;
        }
     },

     async deleteRole() {
        try {
           await this.$store.dispatch('admin/removeRole', this.roleName);
           this.$router.push('/admin/roles').catch(() => {});
           this.$store.commit('admin/clearSelected');
        } catch (e) {
           this.saveError = e.message;
        }
     },
  },
});
</script>

<style lang="scss" scoped>
   .role-detail {
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
