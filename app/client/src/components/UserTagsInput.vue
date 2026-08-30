<!-- Stage 3 of docs/plans/vue2-vue3-migration.md (dockside-admin repo): pulled
     forward from its original Stage 4 slot (a version-bump-only change) once
     Container.vue's live edit-mode testing turned up something worse than a
     style mismatch - @johmun/vue-tags-input reads Vue 2's private
     `this._events` directly (not the documented $on/$off/$emit API @vue/compat's
     INSTANCE_EVENT_EMITTER flag shims), which doesn't exist on a real Vue 3
     instance at all. Confirmed live: every tag add threw
     "Cannot read properties of undefined (reading 'update:tags')" from inside
     the library's own addTag(), and because that read sits in the same
     comma-operator statement as the library's `tags-changed` emit, the throw
     pre-empted the emit too - clicking an autocomplete suggestion added
     nothing. v-autocomplete replaces it outright (not a version bump): this
     mode only ever adds from the known user/role directory
     (add-only-from-autocomplete was already true), so `multiple` + `chips` is
     a direct fit, no free-text branch needed - see ResourceTagsInput.vue's
     v-combobox for the free-entry counterpart. -->
<template>
   <v-autocomplete
      v-model="selectedUserIds"
      :items="autocompleteItems"
      item-title="text"
      item-value="userId"
      multiple chips closable-chips
      :disabled="disabled"
      :placeholder="placeholder"
      density="compact" variant="outlined" hide-details
      class="tags-input"
   />
</template>

<script>
import { defineComponent } from 'vue';

// Deliberately still value/input (not modelValue/update:modelValue): while
// @vue/compat's MODE 2 was in the build (Stages 2-3), its compiler-level
// compatConfig rewrote ANY 'modelValue'-named prop key on a component back
// to 'value', even for an explicit :modelValue binding, not just v-model
// shorthand - confirmed directly on JsonEditor.vue (see its own comment).
// Stage 4 removed @vue/compat entirely (docs/plans/vue2-vue3-migration.md,
// dockside-admin repo), so that rewrite no longer happens, but this
// component's own contract is untouched - not worth modernizing on its own
// without a reason to touch its callers.
export default defineComponent({
  emits: ['input'],
  name: 'UserTagsInput',

  props: {
     disabled: Boolean,
     value: String // Needed for v-model directive; accepts a comma-separated string of user IDs
  },

  computed: {
     // Reactive viewers/roles directory from the account store (seeded from the
     // window.dockside.viewers bootstrap). Reading it from the store rather than the
     // frozen global means admin user mutations and self-edits made in this session
     // are reflected here without a full page reload.
     allUsers() {
        return this.$store.state.account.viewers;
     },
     userNameToUserIDMap() {
        return this.allUsers.reduce((obj, item) => {
           obj[item.name] = item.username;
           return obj;
        }, {});
     },

     // Lookup from username or role metadata name to user's name or human-readable role (respectively)
     userIDToUserNameMap() {
        return this.allUsers.reduce((obj, item) => {
           obj[item.username] = item.name;
           obj[this.role_as_meta(item.role)] = this.roleName(item.role);
           return obj;
        }, {});
     },

     // v-autocomplete's own v-model: an array of the selected userIds
     // (item-value="userId"). The external prop/emit contract stays a
     // comma-joined string - unchanged from the vue-tags-input version, so
     // every caller (Container.vue) needed no changes.
     selectedUserIds: {
        get() {
           return this.value ? this.value.split(',') : [];
        },
        set(ids) {
           this.$emit('input', ids.join(','));
        }
     },

     // The full user+role directory, as {text, userId} pairs. v-autocomplete
     // does its own client-side filter-as-you-type against item-title, so
     // (unlike the old generateAutocompleteItems(currentInput)) this no
     // longer needs to be recomputed per keystroke.
     directoryItems() {
        return this.generateAutocompleteItems();
     },
     // v-autocomplete needs an item entry for every currently-selected id
     // too, even one no longer in the directory (a deleted user, or a role
     // with no current users) - otherwise it can't render that chip's
     // friendly label. Falls back to the same stable label the old
     // selectedUsers getter computed.
     autocompleteItems() {
        const known = new Set(this.directoryItems.map(i => i.userId));
        const extra = this.selectedUserIds
           .filter(id => !known.has(id))
           .map(id => this.generateInternalTagRepresentation(
              this.userIDToUserNameMap[id] || (id.startsWith('role:') ? this.roleName(id.slice(5)) : id),
              id
           ));
        return this.directoryItems.concat(extra);
     },

     placeholder() {
        return this.disabled ? '' : 'Add User or Role';
     }
  },

  methods: {
     generateAutocompleteItems() {
        // First, generate items for users
        const users = this.allUsers.map(
           user => this.generateInternalTagRepresentation(user.name, this.userNameToUserIDMap[user.name])
        );

        // Second, generate items for unique list of roles derived from all users
        const roles = Object.keys(
           this.allUsers
           .map( user => user.role )
           .reduce((obj, item) => { obj[item] = 1; return obj; }, {})
        ).map( role => this.generateInternalTagRepresentation(this.roleName(role), this.role_as_meta(role)) );

        return users.concat(roles);
     },

     generateInternalTagRepresentation(text, userId) {
        return {text, userId};
     },

     // How to display a role in the dropdown
     roleName(role) {
        return role + ' (Role)';
     },

     // How to represent a role in metadata
     role_as_meta(role) {
        return 'role:' + role;
     }
  },
});
</script>
