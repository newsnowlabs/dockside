<template>
   <!-- Stage 3 of docs/plans/vue2-vue3-migration.md (dockside-admin repo): one
        v-navigation-drawer replaces the old desktop b-col + mobile b-sidebar
        pair - :permanent on md+ makes it always-visible and part of the
        layout (offsetting v-main automatically); below md it's Vuetify's
        default temporary/overlay drawer, opened via Header's hamburger
        through the modelValue this component exposes to App.vue. Real
        modelValue/update:modelValue here (not the value/input convention
        Stage 2 forced onto older components) - safe since index.js disables
        @vue/compat's COMPONENT_V_MODEL globally, and this is a fresh
        contract between two components converted in the same pass, not an
        existing caller left untouched. -->
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
import { filteredContainers, routing, routePermissions } from '@/components/mixins';

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
     // Close the drawer (mobile/temporary only), then run the action - one
     // path instead of the old onMobileSelect/direct-call split the two
     // markup copies needed. The mdAndUp guard matters: closing
     // unconditionally looked harmless (surely a permanent drawer just
     // ignores its own modelValue?) but doesn't - confirmed live, every
     // click collapsed the md+ permanent drawer too, because Vuetify's
     // internal "re-open when :permanent becomes true" watcher only fires on
     // *permanent itself* changing, not on modelValue being set false while
     // permanent stays constantly true - see App.vue's drawerOpen comment
     // for the closely related initial-value version of this same gotcha.
     onSelect(action) {
        if (!this.$vuetify.display.mdAndUp) this.$emit('update:modelValue', false);
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
      color: #999;
   }

   // Status colour moved from the list-item's text (its old home) onto its
   // .sidebar-dot instead - unifies with every other sidebar list, all of
   // which now convey their per-item state (or lack of one) the same way:
   // neutral grey text, colour carried by the dot alone. status-1 (running)
   // is new here - previously the "no override, plain text" default, it
   // needs its own colour now a plain dot would otherwise read as identical
   // to an item with no status at all. Reuses the 'started' theme colour
   // (see plugins/vuetify.js) - the same blue Container.vue's own "Started"
   // chip uses, rather than inventing a second "running" colour.
   .status-1  { background: rgb(var(--v-theme-started)); }
   .status-0  { background: #888; }
   .status--1 { background: #c88; }
   .status--2 { background: #ccc; }
   .status--3 { background: #ccc; }
   .status--4 { background: #c44; }
</style>
