<template>
   <v-bottom-navigation color="white" bg-color="#16212c" app class="d-md-none">
      <v-btn to="/" exact :class="{ 'bottom-btn--active': isContainerSection }">
         <v-icon icon="mdi-home"></v-icon>
         Containers
      </v-btn>

      <v-btn v-show="user.permissions.actions.createContainerReservation"
         :class="{ 'bottom-btn--active': isPrelaunchMode }" @click="goToContainer('new', 'prelaunch')">
         <v-icon icon="mdi-plus-circle"></v-icon>
         Launch
      </v-btn>

      <v-btn v-show="canAccessAdmin" to="/admin" :class="{ 'bottom-btn--active': isAdminRoute }">
         <v-icon icon="mdi-cog"></v-icon>
         Admin
      </v-btn>

      <v-btn to="/account" :class="{ 'bottom-btn--active': isAccountRoute }">
         <v-icon icon="mdi-account-circle"></v-icon>
         Account
      </v-btn>
   </v-bottom-navigation>
</template>

<script>
import { defineComponent } from 'vue';

import { mapGetters } from 'vuex';
import { routing, routePermissions } from '@/components/mixins';

export default defineComponent({
  name: 'BottomNav',
  mixins: [routing, routePermissions],

  computed: {
     ...mapGetters(['isPrelaunchMode']),
     user() {
        return this.$store.state.account.currentUser;
     }
  },
});
</script>

<style lang="scss" scoped>
   .bottom-btn--active {
      opacity: 1;
      font-weight: 600;
   }
</style>
