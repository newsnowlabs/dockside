<template>
   <!-- v-app is Vuetify 3's required root wrapper, not decorative: components
        that render into an overlay (v-dialog, v-menu, v-tooltip, ...) look
        for the layout context v-app provides. Without it, such a component
        can update its v-model correctly yet mount no content at all, with no
        error or warning to say why. -->
   <v-app>
      <!-- drawerOpen is lifted here rather than owned by Sidebar/AdminSidebar
           themselves: Header's hamburger (which toggles it) and whichever
           sidebar is currently mounted are siblings, not parent/child, so
           App.vue is the nearest common owner. Vuetify's layout system
           (v-app-bar/v-navigation-drawer/v-main, each registered via its own
           `app` layout participation) handles the spacing math that used to
           be manual CSS here (body padding-top, BottomNav clearance calc). -->
      <Header @toggle-nav="drawerOpen = !drawerOpen"></Header>

      <template v-if="isAdminRoute || isAccountRoute">
         <AdminSidebar v-if="isAdminRoute" v-model="drawerOpen"></AdminSidebar>
      </template>
      <template v-else>
         <Sidebar v-model="drawerOpen"></Sidebar>
      </template>

      <v-main>
         <div class="page-content">
            <template v-if="isAdminRoute || isAccountRoute">
               <AdminMain></AdminMain>
            </template>
            <template v-else>
               <Main></Main>
            </template>
         </div>
      </v-main>

      <SSHInfo></SSHInfo>
      <BottomNav></BottomNav>
   </v-app>
</template>

<script>
import { defineComponent, defineAsyncComponent } from 'vue';

import { routePermissions } from '@/components/mixins';
import Header       from '@/components/Header';
import Sidebar      from '@/components/Sidebar';
import Main         from '@/components/Main';
import SSHInfo      from '@/components/SSHInfo';
import BottomNav    from '@/components/BottomNav';
import AdminSidebar from '@/components/admin/AdminSidebar';

// Lazy rather than a static import: AdminMain pulls in UserDetail/RoleDetail/
// ProfileDetail, which in turn pull in PermissionsEditor/ResourcesEditor/
// SshEditor/JsonEditor - the entire admin-panel surface. A static import here
// puts all of that in every visitor's initial main.js, including non-admin
// users who can never reach /admin (review.md #10). defineAsyncComponent's
// loader only runs the first time the component actually renders, and it's
// only rendered under v-if="isAdminRoute || isAccountRoute" below, so the
// chunk is fetched on first /admin or /account navigation, never before.
const AdminMain = defineAsyncComponent(() => import('@/components/admin/AdminMain'));

export default defineComponent({
  name: 'App',

  components: {
     Header,
     Sidebar,
     Main,
     SSHInfo,
     BottomNav,
     AdminSidebar,
     AdminMain,
  },

  mixins: [routePermissions],

  data() {
     return {
        // v-navigation-drawer only self-initialises to "visible" under
        // :permanent when its modelValue is left undefined at setup (see its
        // own source: `if (props.modelValue == null && !isTemporary.value)
        // isActive.value = props.permanent || !mobile.value`). drawerOpen is
        // bound as an explicit, always-concrete controlled boolean instead
        // (needed so Header's hamburger and the sidebar can share state as
        // siblings), so that self-init branch never runs - the value must be
        // seeded from the actual viewport here, not a flat `false`, or the
        // drawer stays closed/off-screen even once :permanent resolves true.
        drawerOpen: window.matchMedia('(min-width: 960px)').matches,
     };
  },

  computed: {
     user() {
        return this.$store.state.account.currentUser;
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
        } else {
           // Admin/Account routes have no notion of a selected container. Clear any
           // selection (e.g. a stale prelaunch "new" from before navigating here) so
           // BottomNav's isPrelaunchMode-driven Launch tab doesn't stay stuck active.
           this.$store.dispatch('updateSelectedContainerName', undefined);
        }

        if (this.isAdminRoute && route.params.type && route.params.id) {
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
  },
});
</script>

<style lang="scss">
   /* https://css-tricks.com/snippets/css/force-vertical-scrollbar/ */
   html {
      overflow-y: scroll;
   }

   // Vuetify's layout system (v-app-bar/v-navigation-drawer/v-main/v-footer,
   // all registered as layout participants) computes and applies the fixed
   // navbar's height offset itself, so no manual padding-top is set here.
   // The active-nav-link underline rule lives in Header.vue's own
   // .nav-btn--active and BottomNav.vue's .bottom-btn--active, scoped to
   // those components.
   body {
      font-size: 0.9rem;
   }

   // Content gutter for whichever page renders inside v-main (Main.vue or
   // AdminMain.vue) - standardised here, on .page-content (the one shared
   // wrapper both render into below), rather than duplicated per component,
   // so it can't drift out of sync between them, including for any future
   // top-level page. Deliberately NOT on v-main itself:
   // v-main's own padding-* is how Vuetify's layout system offsets content
   // clear of the app-bar/drawer/footer (see its own padding-left:
   // var(--v-layout-left) etc.) - overriding that would break the offset
   // math, not just add a gutter.
   .page-content {
      padding: 20px;
      padding-bottom: 40px;
   }

   @media (min-width: 768px) {
      .page-content {
         padding-left: 40px;
         padding-right: 40px;
      }
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
