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
            allUsers: window.dockside.viewers, // FIXME Make a viewers/users service and provide an accessor to this global data within it
            currentInput: '',
            selectedUserIds: ''
         };
      },
      computed: {
         userNameToUserIDMap() {
            return this.allUsers.reduce((obj, item) => {
               obj[item.name] = item.username;
               return obj;
            }, {});
         },
         userIDToUserNameMap() {
            return this.allUsers.reduce((obj, item) => {
               obj[item.username] = item.name;
               return obj;
            }, {});
         },
         // selectedUserIds property contains a comma-separated string of user IDs, so this computed property represents those IDs as an array of obejcts
         selectedUsers: {
            get() {
               return this.value ? this.value.split(',').map(userId => this.generateInternalTagRepresentation(this.userIDToUserNameMap[userId], userId)) : [];
            },
            set(userObjs) {
               this.selectedUserIds = userObjs.map(user => user.userId).join(',');
               this.$emit('input', this.selectedUserIds );
            }
         },
         placeholder() {
            return this.disabled ? '' : 'Add User';
         }
      },
      methods: {
         generateAutocompleteItems(currentInput) {
            return this.allUsers.map(
               user => user.name
            ).filter(
               name => name.toLowerCase().indexOf(currentInput.toLowerCase()) !== -1
            ).map(
               name => this.generateInternalTagRepresentation(name, this.userNameToUserIDMap[name])
            );
         },
         generateInternalTagRepresentation(text, userId) {
            return {text, userId};
         }
      }
   };
</script>
