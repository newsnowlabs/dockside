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
            return this.$store.state.account.currentUser;
         },
         // Controls which layout branch is rendered in the template:
         // admin/account routes use AdminSidebar + AdminMain; all others use
         // the existing Sidebar + Main (container list view).
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
         // Sync Vuex state with the current URL on initial load (e.g. deep-linked
         // direct navigation to /admin/users/alice).
         this.updateStateFromRoute(this.$route);
         this.pruneURLBasedOnUserPermissions();
         this.$store.dispatch('updateContainers');
         if (this.isAdminRoute && this.canAccessAdmin) {
            this.$store.dispatch('admin/fetchAll');
         }
      },
      methods: {
         // Translate the current URL into Vuex state.  Called once on mount and
         // again on every route change via the $route watcher.
         //
         // Note: this method references this.isAdminRoute / this.isAccountRoute
         // (computed from this.$route.path) while also accepting a `route`
         // parameter whose .params and .query are used for the payload values.
         // In the $route watcher, Vue has already updated this.$route before the
         // watcher fires, so this.isAdminRoute reflects the new route when the
         // method runs — the two sources are therefore always consistent.
         updateStateFromRoute(route) {
            if (!this.isAdminRoute && !this.isAccountRoute) {
               // Standard container route: drive the container list's selection state.
               this.$store.dispatch('updateSelectedContainerName', route.params.name);
               this.$store.dispatch('updateContainersFilter', route.query.cf);
            } else if (this.isAdminRoute && route.params.type && route.params.id) {
               // Detail route (e.g. /admin/users/alice): set the selected item so
               // AdminMain renders the correct detail component.
               // Permission check: only allow types the current user has access to,
               // preventing a URL-crafted route from rendering a forbidden view.
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
            } else if (this.isAdminRoute && !route.params.id) {
               // List route (e.g. /admin/users, or bare /admin): clear any previously
               // selected item so AdminMain shows the placeholder rather than a
               // stale detail view from the previous navigation.
               this.$store.commit('admin/clearSelected');
            }
            // isAccountRoute with no further action: AdminMain renders the account
            // self-edit view unconditionally when isAccountRoute is true.
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
            // Admin errors are scoped to the page that generated them; clear on
            // any navigation so a stale error from a previous action isn't shown.
            this.$store.commit('admin/setError', null);
            // Lazy-load admin data: fetch only when first entering an admin route,
            // using hostResources as the sentinel for "already fetched".
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
