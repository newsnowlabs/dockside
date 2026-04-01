<template>
   <div class="role-detail">

      <!-- Header -->
      <div class="detail-header">
         <h5 class="detail-title">
            {{ isNew ? 'New role' : roleName }}
         </h5>
         <div class="detail-actions" v-if="!isEditMode && !isNew">
            <b-button variant="outline-primary" size="sm" @click="startEdit">Edit</b-button>
            <b-button
               variant="outline-danger"
               size="sm"
               :disabled="deleteDisabled"
               :title="deleteDisabled ? 'Role is assigned to one or more users and cannot be deleted.' : ''"
               @click="$bvModal.show('confirm-modal-role-' + roleName)"
            >Delete</b-button>
         </div>
      </div>

      <b-form @submit.prevent="save">

         <!-- name — only editable when creating -->
         <b-form-group label="Name" label-cols="3">
            <b-form-input
               v-model="form.name"
               :readonly="!isNew"
               :plaintext="!isNew"
               :state="nameState"
               placeholder="alphanumeric, hyphens, underscores"
               trim
            />
            <b-form-invalid-feedback>
               Role name must contain only letters, digits, hyphens and underscores.
            </b-form-invalid-feedback>
         </b-form-group>

         <!-- Permissions -->
         <b-form-group label="Permissions" label-cols="3">
            <PermissionsEditor
               :permissions="form.permissions"
               :allow-inherit="false"
               :perm-default="form.name === 'admin' ? '1' : '0'"
               :readonly="!isEditMode && !isNew"
               @update:permissions="form.permissions = $event"
            />
         </b-form-group>

         <!-- Resources -->
         <b-form-group label="Resources" label-cols="3">
            <ResourcesEditor
               :resources="form.resources"
               :readonly="!isEditMode && !isNew"
               @update:resources="form.resources = $event"
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
         :id="'role-' + roleName"
         :title="'Delete role ' + roleName"
         :message="'Are you sure you want to delete role \'' + roleName + '\'? This cannot be undone.'"
         @confirm="deleteRole"
      />

   </div>
</template>

<script>
   import { mapState, mapGetters } from 'vuex';
   import PermissionsEditor from '@/components/admin/PermissionsEditor';
   import ResourcesEditor   from '@/components/admin/ResourcesEditor';
   import ConfirmModal      from '@/components/shared/ConfirmModal';

   const EMPTY_FORM = () => ({
      name:        '',
      permissions: {},
      resources:   {},
   });

   export default {
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
            form:      EMPTY_FORM(),
            saving:    false,
            saveError: null,
         };
      },

      computed: {
         ...mapState('admin', ['roles', 'users', 'selected']),
         // NOTE: the mapGetters spread for 'isEditMode' is shadowed by the local
         // isEditMode computed below and should be removed to avoid a Vue console
         // warning about duplicate computed properties.
         ...mapGetters('admin', ['isEditMode']),

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

         currentRoleRecord() {
            return this.roles.find(r => r.name === this.roleName) || null;
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
   };
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
