<template>
   <div class="sidebar-wrapper">
      <b-col md="3" lg="2" class="sidebar d-none d-md-block">
         <b-nav vertical class="nav-sidebar">
            <!-- Heading doubles as a link to '/', so there's always a way into the
                 devtainers list regardless of whether this section is currently
                 collapsed or empty. -->
            <b-nav-item class="heading" v-on:click="goHome(false)">My devtainers</b-nav-item>
            <!-- Collapsed while launching: with a long devtainers list, showing it in
                 full here would push the profile links below out of reach without
                 scrolling — exactly what "Launch new" exists to avoid. -->
            <template v-if="!isPrelaunchMode">
               <b-nav-item v-for="container in sidebarContainers"
                  v-bind:key="container.id"
                  v-bind:class="[`status-${parseInt(container.status)} ${container.name === selectedContainer ? 'selected' : ''}`]"
                  v-on:click="goToContainer(container.name, 'view')">
                  {{ container.name }}
               </b-nav-item>
            </template>
         </b-nav>

         <b-nav vertical class="nav-sidebar" v-if="canLaunch && profileNames.length">
            <b-nav-item class="heading" v-on:click="goToContainer('new', 'prelaunch')">Launch new</b-nav-item>
            <!-- Collapsed while viewing a non-empty devtainers list (isContainerSection:
                 '/' or an existing devtainer's own page) — the mirror image of the
                 collapse above, so neither section's full list clutters the other's
                 screen. Stays expanded regardless if there are no devtainers at all;
                 see showProfileList(). -->
            <template v-if="showProfileList">
               <b-nav-item v-for="profileName in profileNames"
                  v-bind:key="'launch-' + profileName"
                  v-on:click="launchWithProfile(profileName)">
                  {{ profiles[profileName].name || profileName }}
               </b-nav-item>
            </template>
         </b-nav>
      </b-col>

      <!-- Mobile off-canvas drawer: same content as the desktop column above, opened
           via Header's hamburger (b-navbar-toggle target="mobile-nav-sidebar"). Keep
           both copies in sync if the list markup changes. -->
      <b-sidebar id="mobile-nav-sidebar" v-model="mobileNavOpen" title="My devtainers" backdrop shadow class="d-md-none">
         <b-nav vertical class="nav-sidebar">
            <b-nav-item class="heading" v-on:click="onMobileSelect(() => goHome(false))">My devtainers</b-nav-item>
            <template v-if="!isPrelaunchMode">
               <b-nav-item v-for="container in sidebarContainers"
                  v-bind:key="container.id"
                  v-bind:class="[`status-${parseInt(container.status)} ${container.name === selectedContainer ? 'selected' : ''}`]"
                  v-on:click="onMobileSelect(() => goToContainer(container.name, 'view'))">
                  {{ container.name }}
               </b-nav-item>
            </template>
         </b-nav>

         <b-nav vertical class="nav-sidebar" v-if="canLaunch && profileNames.length">
            <b-nav-item class="heading" v-on:click="onMobileSelect(() => goToContainer('new', 'prelaunch'))">Launch new</b-nav-item>
            <template v-if="showProfileList">
               <b-nav-item v-for="profileName in profileNames"
                  v-bind:key="'mobile-launch-' + profileName"
                  v-on:click="onMobileSelect(() => launchWithProfile(profileName))">
                  {{ profiles[profileName].name || profileName }}
               </b-nav-item>
            </template>
         </b-nav>
      </b-sidebar>
   </div>
</template>

<script>
   import { mapState, mapGetters } from 'vuex';
   import { filteredContainers, routing, routePermissions } from '@/components/mixins';

   export default {
      name: 'Sidebar',
      data() {
         return {
            mobileNavOpen: false
         };
      },
      created() {
         // Sidebar is part of the persistent app shell (mounted on every route), so
         // it can't rely on Container.vue's prelaunch-gated fetch to keep the
         // profile list fresh. Non-fatal on failure, same as elsewhere this is
         // dispatched — the bootstrap-seeded profiles remain usable.
         this.$store.dispatch('account/fetchLaunchProfiles');
      },
      computed: {
         // isContainerSection (from routePermissions) reads this directly.
         ...mapGetters(['isPrelaunchMode']),
         ...mapState({ profiles: state => state.account.launchProfiles }),
         user() {
            return this.$store.state.account.currentUser;
         },
         canLaunch() {
            return this.user.permissions.actions.createContainerReservation;
         },
         profileNames() {
            return Object.keys(this.profiles || {}).sort();
         },
         showProfileList() {
            // Expanded whenever we're not viewing devtainers (i.e. we're already on
            // the launch route), or when there are no devtainers at all — with
            // nothing in "My devtainers" to begin with, there's no scrolling problem
            // to justify hiding "Launch new" behind an extra click on its heading.
            return !this.isContainerSection || this.sidebarContainers.length === 0;
         }
      },
      methods: {
         onMobileSelect(action) {
            this.mobileNavOpen = false;
            action();
         },
         // Deliberately not goToContainer(): that merges extraQuery onto the
         // *current* route's query, which here would carry forward the
         // previously-selected profile's already-synced field values (image,
         // access, etc.) into the newly-selected profile's form — values that are
         // almost certainly wrong for it (an image string that isn't one of the new
         // profile's own options, or a router key its access schema doesn't even
         // have). A profile nav click should always start from a clean slate: just
         // the chosen profile, nothing else.
         launchWithProfile(profileId) {
            this.$router.push({ name: 'container', params: { name: 'new' }, query: { profile: profileId } }).catch(() => {})
               .then(() => this.$store.dispatch('updateSelectedContainerMode', 'prelaunch'));
         }
      },
      mixins: [filteredContainers, routing, routePermissions],
   };
</script>

<style lang="scss" scoped>
   // Vue 2 SFCs need a single root element, but a b-row expects its direct
   // children to be grid columns. display:contents makes this wrapper
   // layout-transparent so .sidebar still behaves as a direct row child.
   .sidebar-wrapper {
      display: contents;
   }

   .sidebar {
      @media (min-width: 768px) {
         position: fixed;
         top: 56px;
         bottom: 0;
         padding: 20px 0;
         overflow-y: auto; /* Scrollable contents if viewport is shorter than content. */
         background-color: #f5f5f5;
         border-right: 1px solid #eee;
      }
   }

   .nav-item {
      a {
         padding-right: 20px;
         padding-left: 20px;
      }

      &.status--4 a {
         color: #c44;
      }

      &.status--3 a {
         color: #ccc;
      }

      &.status--2 a {
         color: #ccc;
      }

      &.status--1 a {
         color: #c88;
      }

      &.status-0 a {
         color: #888;
      }

      &.heading a {
         // Small-caps section label (Slack/Linear/Notion-style sidebar convention):
         // small, muted, spaced-out uppercase reads as a label for the section
         // rather than a list item, without the admin sidebar's much stronger
         // black-uppercase treatment (too heavy for everyday use here). Distinct
         // from .selected below on more than just font-weight, since a heading and
         // a selected item could otherwise both render bold and look too similar.
         font-size: 0.75rem;
         font-weight: 700;
         letter-spacing: 0.06em;
         text-transform: uppercase;
         color: #999;
         margin-top: 8px;

         &:hover {
            color: #337ab7;
         }
      }

      &.selected a {
         font-weight: bold;
      }
   }
</style>
