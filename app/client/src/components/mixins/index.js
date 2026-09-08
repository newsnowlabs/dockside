import { mdiHome, mdiPlusCircle, mdiCog, mdiAccountCircle } from '@mdi/js';
import copyToClipboard from '@/utilities/copy-to-clipboard';

// Header.vue and BottomNav.vue both render the same 4 nav icons (see
// plugins/vuetify.js's own comment on why these are real @mdi/js imports,
// not @mdi/font glyph names) - shared here rather than each file repeating
// the same import line.
const navIcons = {
   computed: {
      mdiHome: () => mdiHome,
      mdiPlusCircle: () => mdiPlusCircle,
      mdiCog: () => mdiCog,
      mdiAccountCircle: () => mdiAccountCircle,
   },
};

const filteredContainers = {
   computed: {
      filteredContainers() {
         if (this.$store.getters.isPrelaunchMode) {
            return [window.dockside.dummyReservation];
         }

         if (this.$store.state.selectedContainer.name) {
            return this.$store.state.containers.filter(container => container.name === this.$store.state.selectedContainer.name);
         }

         switch (this.$store.state.containersFilter) {
            case 'own':
               return this.$store.state.containers
                  .filter(container => container.meta.owner === this.$store.state.account.currentUser.username);
            case 'shared':
               // Display containers for which:
               return this.$store.state.containers
                  .filter(container => {
                     const { username, role_as_meta } = this.$store.state.account.currentUser;
                     //  the user is the owner
                     return (container.meta.owner === username) ||
                     // the devtainer's developers list includes the user, or the user's role
                     (container.meta.developers && container.meta.developers.split(',').filter(user => (user === username) || (user === role_as_meta)).length) ||
                     // the devtainer's viewers list includes the user, or the user's role
                     (container.meta.viewers && container.meta.viewers.split(',').filter(user => (user === username) || (user === role_as_meta)).length);
                  });
            case 'all':
               return this.$store.state.containers;
            default:
               return [];
         }
      },
      sidebarContainers() {
         return this.$store.state.containers;
      },
      selectedContainer() {
         return this.$store.state.selectedContainer.name;
      }
   }
};

const routePermissions = {
   computed: {
      isAdminRoute() {
         return this.$route.path.startsWith('/admin');
      },
      isAccountRoute() {
         // Match by route name, not path equality: Vue Router's non-strict matching
         // also resolves '/account/' (trailing slash) to this route, and a bare
         // path === '/account' check would misclassify it.
         return this.$route.name === 'account';
      },
      canAccessAdmin() {
         const p = this.$store.state.account.currentUser.permissions.actions;
         return p.manageUsers || p.manageProfiles;
      },
      // Relies on the consuming component also mapping the 'isPrelaunchMode' getter.
      isContainerSection() {
         return !this.isAdminRoute && !this.isAccountRoute && !this.isPrelaunchMode;
      }
   }
};

const sidebarDrawerSelect = {
   methods: {
      // Close the drawer (mobile/temporary only), then run the given action -
      // one shared path for "user picked something in the sidebar". Shared
      // between Sidebar.vue and AdminSidebar.vue to avoid duplication.
      // The mdAndUp guard matters: closing unconditionally would also
      // collapse the md+ permanent drawer, because Vuetify's internal
      // "re-open when :permanent becomes true" watcher only fires on
      // *permanent itself* changing, not on modelValue being set false while
      // permanent stays constantly true - see App.vue's drawerOpen comment
      // for the closely related initial-value version of this same gotcha.
      // Relies on the consuming component emitting 'update:modelValue' for
      // its own drawer prop.
      onSelect(action) {
         if (!this.$vuetify.display.mdAndUp) this.$emit('update:modelValue', false);
         action();
      },
   },
};

const routing = {
   methods: {
      go: function (path) {
         this.$router.push({ path: path }).catch(() => {});
         return false;
      },
      goDocs: function () {
         this.$router.push({ path: '/docs' }).catch(() => {});
      },
      goHome: function (withQuery) {
         this.$router.push({ path: '/', query: (withQuery ? this.$route.query : undefined) }).catch(() => {});
      },
      goBackOrHome: function () {
         this.$router.go(-1);
      },
      goToContainer(name, mode, replace) {
         const query = Object.assign({}, this.$route.query);
         delete query.cf;

         console.log('goToContainer', name, mode, { name: 'container', params: { name }, query });

         if(replace) {
            this.$router.replace({ name: 'container', params: { name }, query }).catch(() => {}) // FIXME: Consider catch scenario handling.
               .then(() => this.$store.dispatch('updateSelectedContainerMode', mode));
         }
         else {
            this.$router.push({ name: 'container', params: { name }, query }).catch(() => {}) // FIXME: Consider catch scenario handling.
               .then(() => this.$store.dispatch('updateSelectedContainerMode', mode));
         }
      }
   }
};

const COPY_FEEDBACK_MS = 1500;

// "Copy" buttons that briefly flash an accent-strong tonal fill after a
// successful copy - color/variant only, never the label text, so a button
// text width never changes and a tightly-packed row (SSHInfo's toolbars,
// Container's per-router action row) never rewraps because of it.
// copiedKey holds whichever key was last copied, not a single boolean, so
// a component with several independent copy buttons (SSHInfo.vue has
// five) doesn't have one button's feedback light up every button's
// template; each call also clears any previous pending reset, so copying
// a second value doesn't cut short by an earlier timer.
const copyable = {
   data() {
      return { copiedKey: null };
   },
   beforeUnmount() {
      clearTimeout(this._copyFeedbackTimeout);
   },
   methods: {
      async copyWithFeedback(key, value) {
         await copyToClipboard(value);
         clearTimeout(this._copyFeedbackTimeout);
         this.copiedKey = key;
         this._copyFeedbackTimeout = setTimeout(() => {
            this.copiedKey = null;
         }, COPY_FEEDBACK_MS);
      },
      isCopied(key) {
         return this.copiedKey === key;
      },
   },
};

export { filteredContainers, navIcons, routing, routePermissions, sidebarDrawerSelect, copyable };
