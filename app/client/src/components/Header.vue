<template>
   <b-navbar toggleable="lg" variant="dark" type="dark" fixed="top">
      <b-navbar-brand v-on:click="goHome(false)"><div><Dockside colour="white"/></div></b-navbar-brand>

      <b-navbar-toggle target="nav-collapse"></b-navbar-toggle>

      <b-collapse id="nav-collapse" is-nav>
         <b-navbar-nav class="w-100" align="right">

            <b-nav-item v-show="!isSelected">
               <select class="selectpicker" id="filterContainers" v-model="containersFilter" v-on:change="onContainersFilterChange">
                  <option value="shared">Shared</option>
                  <option value="all">All</option>
               </select>
            </b-nav-item>

            <b-nav-item v-show="user.permissions.actions.createContainerReservation && !isPrelaunchMode" v-on:click="goToContainer('new', 'prelaunch')"><a href="javascript:">Launch</a></b-nav-item>

            <b-nav-item v-show="!isSelected" to="/docs"><a href="javascript:">Docs</a></b-nav-item>

            <b-nav-item v-show="!isSelected" to="/docksideio"><a href="https://dockside.io/">Dockside.io</a></b-nav-item>

            <b-nav-item v-show="!isSelected" to="/dockside-github"><a href="https://github.com/newsnowlabs/dockside">GitHub</a></b-nav-item>
         </b-navbar-nav>
      </b-collapse>
   </b-navbar>
</template>

<script>
   import { mapState } from 'vuex';
   import { mapGetters } from 'vuex';
   import { routing } from '@/components/mixins';
   import Dockside from '@/components/Dockside';

   export default {
      name: 'Header',
      components: {
         Dockside
      },
      data() {
         return {
            user: window.dockside.user
         };
      },
      computed: {
         ...mapGetters([
            'isSelected',
            'isPrelaunchMode'
         ]),
         ...mapState([
         ]),
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
</style>
