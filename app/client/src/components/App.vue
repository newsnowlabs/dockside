<template>
   <div>
      <b-container fluid>
         <Header></Header>
         <b-row>
            <template v-if="isAdminRoute || isAccountRoute">
               <AdminSidebar v-if="isAdminRoute"></AdminSidebar>
               <AdminMain></AdminMain>
            </template>
            <template v-else>
               <Sidebar></Sidebar>
               <Main></Main>
            </template>
            <SSHInfo></SSHInfo>
         </b-row>
      </b-container>
      <Footer></Footer>
   </div>
</template>

<script>
   import Header       from '@/components/Header';
   import Footer       from '@/components/Footer';
   import Sidebar      from '@/components/Sidebar';
   import Main         from '@/components/Main';
   import SSHInfo      from '@/components/SSHInfo';
   import AdminSidebar from '@/components/admin/AdminSidebar';
   import AdminMain    from '@/components/admin/AdminMain';

   export default {
      name: 'App',
      components: {
         Header,
         Footer,
         Sidebar,
         Main,
         SSHInfo,
         AdminSidebar,
         AdminMain,
      },
      computed: {
         user() {
            return this.$store.state.currentUser;
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
      },
      created() {
         this.updateStateFromRoute(this.$route);
         this.pruneURLBasedOnUserPermissions();
         this.$store.dispatch('updateContainers');
         if (this.isAdminRoute && this.canAccessAdmin) {
            this.$store.dispatch('admin/fetchAll');
         }
      },
      methods: {
         updateStateFromRoute(route) {
            if (!this.isAdminRoute && !this.isAccountRoute) {
               this.$store.dispatch('updateSelectedContainerName', route.params.name);
               this.$store.dispatch('updateContainersFilter', route.query.cf);
            } else if (this.isAdminRoute && route.params.type && route.params.id) {
               const p = this.user.permissions.actions;
               const allowedRouteTypes = [
                  ...(p.manageUsers    ? ['users', 'roles']  : []),
                  ...(p.manageProfiles ? ['profiles']        : []),
               ];
               const typeMap = { users: 'user', roles: 'role', profiles: 'profile' };
               const type = typeMap[route.params.type];
               if (type && allowedRouteTypes.includes(route.params.type)) {
                  this.$store.commit('admin/setSelected', { type, id: route.params.id, mode: 'view' });
               }
            }
         },
         pruneURLBasedOnUserPermissions() {
            // If user can't develop and 'own' containers is their default view,
            // then remove this query param from the url.
            if ((this.$route.query.cf === 'own') && !this.user.permissions.actions.developContainers) {
               const query = Object.assign({}, this.$route.query);
               delete query.cf;
               this.$router.replace({ path: '/', query });
            }
         }
      },
      watch: {
         $route(to) {
            this.updateStateFromRoute(to);
            // Fetch admin data when entering admin routes for the first time
            if (to.path.startsWith('/admin') && this.canAccessAdmin &&
                !this.$store.state.admin.hostResources) {
               this.$store.dispatch('admin/fetchAll');
            }
         }
      }
   };
</script>

<style lang="scss">
   /* https://css-tricks.com/snippets/css/force-vertical-scrollbar/ */
   html {
      overflow-y: scroll;
   }

   body {
      font-size: 0.9rem;
      padding-top: 58px; /* Move down content because we have a fixed navbar that is 56px tall */
   }

   // Active nav link: underline on dark navbar
   .navbar-dark .navbar-nav .nav-link.router-link-active {
      border-bottom: 2px solid rgba(255, 255, 255, 0.65);
      padding-bottom: 3px;
   }

   /* Define MacOS Safari scrollbar appearance */
   ::-webkit-scrollbar {
      -webkit-appearance: none;
      width: 7px;
   }

   ::-webkit-scrollbar-thumb {
      border-radius: 4px;
      background-color: rgba(0, 0, 0, .5);
      -webkit-box-shadow: 0 0 1px rgba(255, 255, 255, .5);
   }
</style>
