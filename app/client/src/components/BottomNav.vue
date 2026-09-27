<template>
   <!-- :active (not a d-md-none CSS class) drives both visibility and Vuetify's layout-space
        reservation for a v-bottom-navigation: `active` defaults to true regardless of viewport,
        and useLayoutItem() reserves its full height in v-main's padding calc whenever active is
        true - a CSS class only hides it visually, leaving the reserved space behind on desktop. -->
   <v-bottom-navigation color="white" bg-color="chrome" app :active="!$vuetify.display.mdAndUp">
      <v-btn to="/" exact :class="{ 'bottom-btn--active': isContainerSection }">
         <v-icon :icon="mdiHome"></v-icon>
         Containers
      </v-btn>

      <v-btn v-show="user.permissions.actions.createContainerReservation"
         :class="{ 'bottom-btn--active': isPrelaunchMode }" @click="goToContainer('new', 'prelaunch')">
         <v-icon :icon="mdiPlusCircle"></v-icon>
         Launch
      </v-btn>

      <v-btn v-show="canAccessAdmin" to="/admin" :class="{ 'bottom-btn--active': isAdminRoute }">
         <v-icon :icon="mdiCog"></v-icon>
         Admin
      </v-btn>

      <v-btn to="/account" :class="{ 'bottom-btn--active': isAccountRoute }">
         <v-icon :icon="mdiAccountCircle"></v-icon>
         Account
      </v-btn>
   </v-bottom-navigation>
</template>

<script>
import { defineComponent } from 'vue';

import { mapGetters } from 'vuex';
import { routing, routePermissions, navIcons } from '@/components/mixins';

export default defineComponent({
  name: 'BottomNav',
  mixins: [routing, routePermissions, navIcons],

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
