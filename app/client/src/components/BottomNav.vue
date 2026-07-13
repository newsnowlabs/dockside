<template>
   <b-navbar variant="dark" type="dark" fixed="bottom" class="bottom-nav d-md-none">
      <b-navbar-nav class="w-100" fill>
         <b-nav-item to="/" exact :active="isContainerSection">
            <b-icon icon="house-door-fill" class="nav-icon" /><br>Containers
         </b-nav-item>

         <b-nav-item v-show="user.permissions.actions.createContainerReservation" :active="isPrelaunchMode" v-on:click="goToContainer('new', 'prelaunch')">
            <b-icon icon="plus-circle-fill" class="nav-icon" /><br>Launch
         </b-nav-item>

         <b-nav-item v-show="canAccessAdmin" to="/admin" :active="isAdminRoute">
            <b-icon icon="gear-fill" class="nav-icon" /><br>Admin
         </b-nav-item>

         <b-nav-item to="/account" :active="isAccountRoute">
            <b-icon icon="person-circle" class="nav-icon" /><br>Account
         </b-nav-item>
      </b-navbar-nav>
   </b-navbar>
</template>

<script>
   import { mapGetters } from 'vuex';
   import { routing, routePermissions } from '@/components/mixins';

   export default {
      name: 'BottomNav',
      mixins: [routing, routePermissions],
      computed: {
         ...mapGetters(['isPrelaunchMode']),
         user() {
            return this.$store.state.account.currentUser;
         }
      }
   };
</script>

<style lang="scss" scoped>
   // Height must match the extra body/footer bottom padding reserved in Footer.vue,
   // so this fixed bar never overlaps page or footer content.
   //
   // transform/will-change force this fixed element onto its own GPU compositor
   // layer, cheap insurance against position:fixed jank during reflow-heavy
   // periods elsewhere on the page (e.g. the router's forced scroll-to-top on
   // navigation). The specific flicker that prompted this bar's investigation
   // traced to the container list's now-removed enter/leave transition, not a
   // mobile-engine-specific rendering quirk — it reproduced under desktop
   // Chrome's device-emulation mode too.
   .bottom-nav {
      height: 56px;
      padding: 0;
      transform: translateZ(0);
      will-change: transform;

      .nav-item {
         flex: 1 1 0;
         text-align: center;

         a {
            display: block;
            padding: 6px 0 4px;
            color: #ccc;
            font-size: 0.7rem;
            line-height: 1.2;

            &:hover {
               color: #bbb;
               text-decoration: none;
            }

            &.active {
               color: #fff;
            }
         }
      }

      .nav-icon {
         font-size: 1.15rem;
      }
   }
</style>
