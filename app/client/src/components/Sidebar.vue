<template>
   <!-- One v-navigation-drawer serves as the sidebar at every viewport size:
        :permanent on md+ makes it always-visible and part of the layout
        (offsetting v-main automatically); below md it's Vuetify's default
        temporary/overlay drawer, opened via Header's hamburger through the
        modelValue this component exposes to App.vue. It exposes a plain
        modelValue/update:modelValue contract - Vue 3's native v-model -
        since App.vue is its only caller. -->
   <v-navigation-drawer
      :model-value="modelValue"
      @update:model-value="$emit('update:modelValue', $event)"
      :permanent="$vuetify.display.mdAndUp"
      width="260"
   >
      <v-list nav density="compact">
         <v-list-item class="sb-heading" @click="onSelect(() => goHome(false))">
            <v-list-item-title>My devtainers</v-list-item-title>
         </v-list-item>
         <!-- Collapsed while launching: with a long devtainers list, showing it in
              full here would push the profile links below out of reach without
              scrolling — exactly what "Launch new" exists to avoid. -->
         <template v-if="!isPrelaunchMode">
            <v-list-item v-for="container in sidebarContainers"
               :key="container.id"
               :active="container.name === selectedContainer"
               :class="{ 'status-removed': container.status === -3 }"
               @click="onSelect(() => goToContainer(container.name, 'view'))"
            >
               <template #prepend>
                  <span class="sidebar-dot" :class="statusClass(container)"></span>
               </template>
               <v-list-item-title>{{ container.name }}</v-list-item-title>
            </v-list-item>
         </template>
      </v-list>

      <v-list nav density="compact" v-if="canLaunch && profileNames.length">
         <v-list-item class="sb-heading" @click="onSelect(() => goToContainer('new', 'prelaunch'))">
            <v-list-item-title>Launch new</v-list-item-title>
         </v-list-item>
         <!-- Collapsed while viewing a non-empty devtainers list (isContainerSection:
              '/' or an existing devtainer's own page) — the mirror image of the
              collapse above, so neither section's full list clutters the other's
              screen. Stays expanded regardless if there are no devtainers at all;
              see showProfileList(). -->
         <template v-if="showProfileList">
            <v-list-item v-for="profileName in profileNames"
               :key="'launch-' + profileName"
               @click="onSelect(() => launchWithProfile(profileName))"
            >
               <template #prepend>
                  <span class="sidebar-dot"></span>
               </template>
               <v-list-item-title>{{ profiles[profileName].name || profileName }}</v-list-item-title>
            </v-list-item>
         </template>
      </v-list>
   </v-navigation-drawer>
</template>

<script>
import { defineComponent } from 'vue';

import { mapState, mapGetters } from 'vuex';
import { filteredContainers, routing, routePermissions, sidebarDrawerSelect } from '@/components/mixins';

export default defineComponent({
  name: 'Sidebar',
  props: {
     modelValue: { type: Boolean, default: false },
  },
  emits: ['update:modelValue'],

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
     statusClass(container) {
        return `status-${parseInt(container.status)}`;
     },
     // onSelect (close the drawer, then run the action) comes from the
     // sidebarDrawerSelect mixin (components/mixins/index.js) - shared with
     // AdminSidebar.vue, see its own comment there for the mdAndUp guard's
     // reasoning.
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

  mixins: [filteredContainers, routing, routePermissions, sidebarDrawerSelect],
});
</script>

<style lang="scss" scoped>
   .sb-heading :deep(.v-list-item-title) {
      // Small-caps section label (Slack/Linear/Notion-style sidebar convention):
      // small, muted, spaced-out uppercase reads as a label for the section
      // rather than a list item, without the admin sidebar's much stronger
      // black-uppercase treatment (too heavy for everyday use here).
      font-size: 0.75rem;
      font-weight: 700;
      letter-spacing: 0.06em;
      text-transform: uppercase;
      color: rgb(var(--v-theme-ink-soft));
   }

   // Status colour is carried by the .sidebar-dot, not the list-item's text -
   // unifies with every other sidebar list, all of which convey their
   // per-item state (or lack of one) the same way: neutral grey text, colour
   // carried by the dot alone. status-1 (running) gets its own colour here
   // because a plain, uncoloured dot would otherwise read as identical to an
   // item with no status at all. Reuses the 'started' theme colour (see
   // plugins/vuetify.js) - the same green Container.vue's own "Started" chip
   // uses, rather than inventing a second "running" colour.
   //
   // .status-removed (below) is the one deliberate exception to "colour
   // carried by the dot alone": a dot's colour/opacity alone reads as too
   // subtle a cue at this size, so a destroyed-but-unreclaimed reservation
   // dims its title text too.
   .status-1  { background: rgb(var(--v-theme-started)); }
   // 0/-1/-2 (exited / created-not-started / launch-in-flight - see
   // Reservation.pm's own status derivation) are all "not running, not
   // failed" - one shared neutral dot rather than 3 shades the design
   // system has no dedicated token for. -4 (create failed) is the one
   // genuine error state among them, so it alone gets the danger token.
   .status-0  { background: rgb(var(--v-theme-neutral)); }
   .status--1 { background: rgb(var(--v-theme-neutral)); }
   .status--2 { background: rgb(var(--v-theme-neutral)); }
   // -3 (destroyed: the container is gone but this reservation hasn't been
   // reclaimed yet) stays navigable like any other item, but shouldn't read
   // as merely "stopped" - the container itself no longer exists. Dimmed to
   // Vuetify's own disabled-state opacity (see index.scss's readonly-field
   // comment) rather than a lighter background token: at this dot's 7px
   // size, a lighter fill washes out to near-invisible in the light theme,
   // where opacity stays visibly distinct in both themes.
   .status--3 { background: rgb(var(--v-theme-neutral)); opacity: 0.38; }
   .status--4 { background: rgb(var(--v-theme-danger)); }

   // Same disabled-state opacity as .status--3's own dot, applied to the row's
   // title text as well - see this style block's opening comment.
   .status-removed :deep(.v-list-item-title) {
      opacity: 0.38;
   }
</style>
