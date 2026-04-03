<template>
   <b-navbar toggleable="lg" variant="dark" type="dark" fixed="top">
      <b-navbar-brand v-on:click="goHome(false)"><div><Dockside colour="white"/></div></b-navbar-brand>

      <b-navbar-toggle target="nav-collapse"></b-navbar-toggle>

      <b-collapse id="nav-collapse" is-nav>
         <b-navbar-nav class="w-100" align="right">

            <b-nav-item v-show="!isSelected && !isAdminRoute && !isAccountRoute">
               <select class="selectpicker" id="filterContainers" v-model="containersFilter" v-on:change="onContainersFilterChange">
                  <option value="shared">Shared</option>
                  <option value="all">All</option>
               </select>
            </b-nav-item>

            <b-nav-item v-show="user.permissions.actions.createContainerReservation && !isPrelaunchMode && !isAccountRoute" v-on:click="goToContainer('new', 'prelaunch')"><a href="javascript:">Launch</a></b-nav-item>

            <b-nav-item v-show="!isSelected && !isAccountRoute" to="/docs"><a href="javascript:">Docs</a></b-nav-item>

            <b-nav-item v-show="!isSelected && !isAdminRoute && !isAccountRoute" to="/docksideio"><a href="https://dockside.io/">Dockside.io</a></b-nav-item>

            <b-nav-item v-show="!isSelected && !isAdminRoute && !isAccountRoute" to="/dockside-github"><a href="https://github.com/newsnowlabs/dockside">GitHub</a></b-nav-item>

            <b-nav-item v-show="canAccessAdmin" to="/admin"><a href="javascript:"><b-icon icon="gear-fill" class="nav-icon" /> Admin</a></b-nav-item>

            <b-nav-item to="/account"><a href="javascript:" :title="'Account settings for ' + user.username"><b-icon icon="person-circle" class="nav-icon" /> {{ displayName }}</a></b-nav-item>
         </b-navbar-nav>
      </b-collapse>
   </b-navbar>
</template>

<script>
   import { mapGetters } from 'vuex';
   import { routing } from '@/components/mixins';
   import Dockside from '@/components/Dockside';

   export default {
      name: 'Header',
      components: {
         Dockside
      },
      computed: {
         ...mapGetters(['isSelected', 'isPrelaunchMode']),
         user() {
            return this.$store.state.account.currentUser;
         },
         displayName() {
            const { name, email, username } = this.user;
            // Prefer first name, then surname — both come from the same 'name' field.
            // A multi-word name yields the first word; a single-word name is treated as
            // a surname and used directly.
            if (name) {
               const words = name.trim().split(/\s+/).filter(Boolean);
               if (words.length) return words[0];
            }
            if (email) {
               // Slightly obfuscate: keep first 1–3 chars of local part + … + @domain
               return email.replace(/^(.{1,3})[^@]*(@.+)$/, '$1\u2026$2');
            }
            return username;
         },
         isAdminRoute() {
            return this.$route.path.startsWith('/admin');
         },
         isAccountRoute() {
            return this.$route.path === '/account';
         },
         canAccessAdmin() {
            const p = this.user.permissions.actions;
            return p.manageUsers || p.manageProfiles;
         },
         containersFilter: {
            get() {
               return this.$store.state.containersFilter;
            },
            set(filter) {
               this.$store.dispatch('updateContainersFilter', filter);
            }
         }
      },
      methods: {
         onContainersFilterChange() {
            switch (this.$store.state.containersFilter) {
               case 'all':
               case 'own': {
                  this.$router.push({ path: '/', query: Object.assign({}, this.$route.query, { cf: this.$store.state.containersFilter }) });
                  break;
               }
               case 'shared': {
                  const query = Object.assign({}, this.$route.query);

                  // Delete cf param rather than set to 'all'.
                  delete query.cf;

                  this.$router.push({ path: '/', query });
                  break;
               }
            }
         },
         refresh() {
            this.$store.dispatch('updateContainers', 1);
         }
      },
      mixins: [routing]
   };
</script>

<style lang="scss" scoped>

   .navbar-brand {
      cursor: pointer;

      padding-top: 0px;

      > div {
         font-size: 32px;

         > .dockside {
            float: left;
         }

      }
   }

   a {
      color: #fff;

      &:hover {
         color: #bbb;
         text-decoration: none;
      }
   }

   .nav-icon {
      vertical-align: -0.1em;
      margin-right: 2px;
   }
</style>
