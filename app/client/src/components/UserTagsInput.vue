<template>
   <vue-tags-input
      v-model="currentInput"
      :tags="selectedUsers"
      :add-on-key="[13,',',' ']"
      :allow-edit-tags="false"
      :add-only-from-autocomplete="true"
      :autocomplete-items="generateAutocompleteItems(currentInput)"
      :disabled="disabled"
      :placeholder="placeholder"
      class="tags-input"
      @tags-changed="newTags => selectedUsers = newTags">
   </vue-tags-input>
</template>

<style lang="scss">
// Hide the X for deleting tables when this component is disabled.
.vue-tags-input.ti-disabled .ti-icon-close:before { content: ""; }
</style>

<script>
   import VueTagsInput from '@johmun/vue-tags-input'; // http://www.vue-tags-input.com/

   export default {
      name: 'UserTagsInput',
      components: {
         VueTagsInput,
      },
      props: {
         disabled: Boolean,
         value: String // Needed for v-model directive; accepts a comma-separated string of user IDs
      },
      data() {
         return {
            currentInput: '',
            selectedUserIds: ''
         };
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

         // selectedUserIds property contains a comma-separated string of user IDs, so this computed property represents those IDs as an array of obejcts
         selectedUsers: {
            get() {
               return this.value ? this.value.split(',').map(userId => {
                  // Stable label when the id isn't in the directory (a deleted user, or a
                  // role with no current users): the username for a user id, '<name> (Role)'
                  // for a 'role:<name>' id. Never undefined — the tags library treats an
                  // undefined text as malformed and can drop the userId.
                  const label = this.userIDToUserNameMap[userId]
                     || (userId.startsWith('role:') ? this.roleName(userId.slice(5)) : userId);
                  return this.generateInternalTagRepresentation(label, userId);
               }) : [];
            },
            set(userObjs) {
               this.selectedUserIds = userObjs.map(user => user.userId).join(',');
               this.$emit('input', this.selectedUserIds );
            }
         },

         placeholder() {
            return this.disabled ? '' : 'Add User or Role';
         }
      },

      methods: {
         generateAutocompleteItems(currentInput) {
            // First, generate items for users
            const users = this.allUsers.map(
               user => user.name
            ).filter(
               name => name.toLowerCase().indexOf(currentInput.toLowerCase()) !== -1
            ).map(
               name => this.generateInternalTagRepresentation(name, this.userNameToUserIDMap[name])
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
      }
   };
</script>
