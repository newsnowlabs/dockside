<template>
   <div class="permissions-editor">
      <div
         v-for="group in groupedPermissions"
         :key="group.name"
         class="permissions-group"
      >
         <div class="permissions-group-label">{{ group.name }}</div>
         <div class="permissions-group-tags">
            <ValueTag
               v-for="perm in group.items"
               :key="perm.key"
               :label="perm.label"
               :value="tagValue(perm.key)"
               :allow-inherit="allowInherit"
               :title="tagTitle(perm)"
               @change="onTagChange(perm.key, $event)"
            />
         </div>
      </div>
      <div v-if="allowInherit" class="permissions-legend">
         <span class="legend-item legend-absent">Grey = inherited from role</span>
         <span class="legend-item legend-granted">Green ✓ = explicitly granted</span>
         <span class="legend-item legend-denied">Red ✗ = explicitly denied</span>
      </div>
   </div>
</template>

<script>
   import { groupedPermissions } from '@/schemas/admin';
   import ValueTag from '@/components/shared/ValueTag';

   export default {
      name: 'PermissionsEditor',
      components: { ValueTag },

      props: {
         // { permissionKey: "1" | "0" }  — only explicitly set values; absent = inherited
         permissions: {
            type: Object,
            default: () => ({}),
         },
         // For user context: the effective permissions of the user's role (for hint display)
         rolePermissions: {
            type: Object,
            default: () => ({}),
         },
         // false for roles (no inheritance); true for users
         allowInherit: {
            type: Boolean,
            default: true,
         },
         readonly: {
            type: Boolean,
            default: false,
         },
      },

      computed: {
         groupedPermissions() {
            return groupedPermissions();
         },
      },

      methods: {
         tagValue(key) {
            const v = this.permissions[key];
            if (v === '1' || v === 1 || v === true)  return '1';
            if (v === '0' || v === 0 || v === false) return '0';
            return null;
         },

         tagTitle(perm) {
            const { key, label } = perm;
            const v  = this.tagValue(key);
            const rp = this.rolePermissions[key];

            if (this.readonly) {
               if (v === '1') return `${label}: explicitly granted`;
               if (v === '0') return `${label}: explicitly denied`;
               if (!this.allowInherit) return `${label}: not granted`;
               const roleStr = (rp === '1' || rp === 1 || rp === true)  ? 'granted'
                             : (rp === '0' || rp === 0 || rp === false) ? 'denied'
                             : 'not set';
               return `${label}: inherited from role (${roleStr})`;
            }

            if (!this.allowInherit) {
               // Role context: null = not granted, "1" = granted
               return v === '1'
                  ? `${label}: granted — click to remove`
                  : `${label}: not granted — click to grant`;
            }

            // User context: null = inherited, "1" = explicit grant, "0" = explicit deny
            if (v === '1') return `${label}: explicitly granted — click to deny`;
            if (v === '0') return `${label}: explicitly denied — click to allow`;
            const roleStr = (rp === '1' || rp === 1 || rp === true)  ? 'granted'
                          : (rp === '0' || rp === 0 || rp === false) ? 'denied'
                          : 'not set';
            return `${label}: inherited from role (${roleStr}) — click to grant explicitly`;
         },

         onTagChange(key, newValue) {
            if (this.readonly) return;
            const updated = { ...this.permissions };
            if (newValue === null) {
               delete updated[key];
            } else {
               updated[key] = newValue;
            }
            this.$emit('update:permissions', updated);
         },
      },
   };
</script>

<style lang="scss" scoped>
   .permissions-editor {
      font-size: 0.85rem;
   }

   .permissions-group {
      margin-bottom: 10px;
   }

   .permissions-group-label {
      font-weight: 600;
      color: #495057;
      font-size: 0.75rem;
      text-transform: uppercase;
      letter-spacing: 0.05em;
      margin-bottom: 4px;
   }

   .permissions-group-tags {
      display: flex;
      flex-wrap: wrap;
   }

   .permissions-legend {
      margin-top: 8px;
      display: flex;
      flex-wrap: wrap;
      gap: 10px;
      font-size: 0.75rem;
      color: #6c757d;
   }
</style>
