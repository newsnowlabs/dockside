<template>
   <b-col md="9" lg="10" offset-md="3" offset-lg="2" class="admin-main">

      <div v-if="error && !isAccountRoute" class="alert alert-danger mb-3">
         {{ error }}
         <b-button variant="link" size="sm" class="float-right p-0" @click="clearError">✕</b-button>
      </div>

      <!-- User detail -->
      <UserDetail
         v-if="!isAccountRoute && selected.type === 'user' && selected.id"
         :key="'user-' + selected.id"
         :username="selected.id === 'new' ? null : selected.id"
         :self-edit="false"
      />

      <!-- Role detail -->
      <RoleDetail
         v-else-if="!isAccountRoute && selected.type === 'role' && selected.id"
         :key="'role-' + selected.id"
         :role-name="selected.id === 'new' ? null : selected.id"
      />

      <!-- Profile detail -->
      <ProfileDetail
         v-else-if="!isAccountRoute && selected.type === 'profile' && selected.id"
         :key="'profile-' + selected.id"
         :profile-id="selected.id === 'new' ? null : selected.id"
      />

      <!-- Account self-edit -->
      <UserDetail
         v-else-if="isAccountRoute"
         :key="'account-self'"
         :username="currentUsername"
         :self-edit="true"
      />

      <!-- Placeholder -->
      <div v-else class="admin-placeholder">
         <p>Select an item from the sidebar, or click <em>+ New …</em> to create one.</p>
      </div>

   </b-col>
</template>

<script>
   import { mapState } from 'vuex';
   import UserDetail    from '@/components/admin/UserDetail';
   import RoleDetail    from '@/components/admin/RoleDetail';
   import ProfileDetail from '@/components/admin/ProfileDetail';

   export default {
      name: 'AdminMain',
      components: { UserDetail, RoleDetail, ProfileDetail },

      computed: {
         ...mapState('admin', ['selected', 'error']),

         isAccountRoute() {
            return this.$route.path === '/account';
         },

         currentUsername() {
            return this.$store.state.currentUser.username;
         },
      },

      methods: {
         clearError() {
            this.$store.commit('admin/setError', null);
         },
      },
   };
</script>

<style lang="scss" scoped>
   .admin-main {
      padding-top: 20px;
      padding-bottom: 40px;
   }

   .admin-placeholder {
      color: #888;
      font-style: italic;
      padding: 40px 0;
      text-align: center;
   }
</style>
