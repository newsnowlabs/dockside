<!-- v-autocomplete: this component only ever adds from the known user/role
     directory (add-only-from-autocomplete), so `multiple` + `chips` is a
     direct fit, with no free-text branch needed - see ResourceTagsInput.vue's
     v-combobox for the free-entry counterpart. -->
<template>
   <v-autocomplete
      v-model="selectedUserIds"
      :items="autocompleteItems"
      item-title="text"
      item-value="userId"
      multiple chips
      :closable-chips="!readonly"
      :disabled="disabled"
      :readonly="readonly"
      :placeholder="placeholder"
      autocomplete="off"
      hide-details
      class="tags-input"
   />
</template>

<script>
import { defineComponent } from 'vue';

// Deliberately still value/input (not modelValue/update:modelValue), matching
// this component's own external contract: its caller (Container.vue) binds
// it via explicit :value/@input rather than v-model. Modernizing this prop
// naming is a Container.vue-conversion-time decision, not this one - it
// would mean editing that call site for no behavioural gain.
export default defineComponent({
  emits: ['input'],
  name: 'UserTagsInput',

  props: {
     disabled: Boolean,
     readonly: Boolean,
     // Shown in place of 'Add User or Role' when readonly and empty - the
     // caller's own wording for "nothing configured here yet" (e.g.
     // Container.vue's distinct developers/viewers empty-state text).
     emptyPlaceholder: { type: String, default: 'None added' },
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
        if (this.readonly) return this.selectedUserIds.length ? '' : this.emptyPlaceholder;
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
