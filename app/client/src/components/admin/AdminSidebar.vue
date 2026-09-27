<template>
   <!-- A single v-navigation-drawer serves both the desktop (permanent) and
        mobile (overlay) layouts - see Sidebar.vue's own comment for the same
        pattern and the modelValue/COMPONENT_V_MODEL reasoning. Each section
        is a v-list-group, Vuetify's own collapsible-header primitive. Its
        default per-nesting-level indent is turned off app-wide
        (plugins/vuetify.js's VListGroup default, not a `fluid` prop here) -
        see that file's own comment for why. -->
   <v-navigation-drawer
      :model-value="modelValue"
      @update:model-value="$emit('update:modelValue', $event)"
      :permanent="$vuetify.display.mdAndUp"
      width="260"
   >
      <v-list nav density="compact" v-model:opened="openSections">
         <v-list-group v-for="section in visibleSections" :key="section.type" :value="section.type">
            <template #activator="{ props: activatorProps, isOpen }">
               <v-list-item v-bind="activatorProps" class="sb-section-heading">
                  <span class="sb-title-row">
                     {{ section.label }}
                     <v-icon :icon="mdiChevronRight" size="16" class="sb-caret" :class="{ 'sb-caret--open': isOpen }"></v-icon>
                  </span>
                  <template #append>
                     <span class="sb-add" @click.stop="onSelect(() => selectItem(section.type, 'new'))">+ New</span>
                  </template>
               </v-list-item>
            </template>

            <!-- Loading placeholder -->
            <v-list-item v-if="loading" disabled class="loading-item">
               <v-list-item-title>Loading…</v-list-item-title>
            </v-list-item>

            <!-- Items -->
            <template v-else>
               <v-list-item
                  v-for="item in itemsFor(section.type)"
                  :key="item.id"
                  :active="isSelected(section.type, item.id)"
                  @click="onSelect(() => selectItem(section.type, item.id))"
               >
                  <template #prepend>
                     <span v-if="section.type === 'profile'"
                        class="sidebar-dot" :class="item.active ? 'dot-active' : 'dot-inactive'" title="active/inactive"
                     ></span>
                     <span v-else class="sidebar-dot"></span>
                  </template>
                  <v-list-item-title>{{ item.label }}</v-list-item-title>
               </v-list-item>
            </template>
         </v-list-group>
      </v-list>
   </v-navigation-drawer>
</template>

<script>
import { defineComponent } from 'vue';
import { mdiChevronRight } from '@mdi/js';

import { mapState, mapGetters } from 'vuex';
import { sidebarDrawerSelect } from '@/components/mixins';

// `route` is the plural path segment used under /admin/<route>/<id> - both
// selectItem() (building that URL) and currentSectionType (reading it back
// out of $route.params.type) key off the same table rather than each
// keeping its own type<->route-segment mapping.
const SECTIONS = [
   { type: 'user',    label: 'USERS',    singular: 'user',    route: 'users'    },
   { type: 'role',    label: 'ROLES',    singular: 'role',    route: 'roles'    },
   { type: 'profile', label: 'PROFILES', singular: 'profile', route: 'profiles' },
];

export default defineComponent({
  name: 'AdminSidebar',
  mixins: [sidebarDrawerSelect],
  props: {
     modelValue: { type: Boolean, default: false },
  },
  emits: ['update:modelValue'],

  data() {
     return {
        // Starts open on whichever section the current route names (see
        // currentSectionType below) - e.g. landing directly on
        // /admin/roles/developer opens ROLES only, not all three. Bare
        // /admin (no :type at all) has no section to prefer, so nothing
        // starts open. The $route watcher below is what keeps this in sync
        // on navigation thereafter.
        openSections: this.sectionTypeForRoute(this.$route) ? [this.sectionTypeForRoute(this.$route)] : [],
     };
  },

  computed: {
     ...mapState('admin', ['users', 'roles', 'profiles', 'selected', 'loading']),

     ...mapGetters('admin', ['isEditMode']),

     mdiChevronRight: () => mdiChevronRight,

     // The section (if any) the current route names, independent of
     // state.admin.selected - a list route like /admin/roles (no :id) still
     // names ROLES here even though App.vue's updateStateFromRoute clears
     // `selected` entirely for it (selected only ever reflects a specific
     // detail route).
     currentSectionType() {
        return this.sectionTypeForRoute(this.$route);
     },

     // Filter the SECTIONS list down to only those the current user has
     // permission to manage.  A user with only manageProfiles sees no Users
     // or Roles sections; a user with only manageUsers sees no Profiles section.
     visibleSections() {
        const p = this.$store.state.account.currentUser.permissions.actions;
        return SECTIONS.filter(s => {
           if (s.type === 'user' || s.type === 'role') return !!p.manageUsers;
           if (s.type === 'profile')                   return !!p.manageProfiles;
           return true;
        });
     },
  },

  methods: {
     // The section (if any) whose route segment matches route.params.type -
     // shared by the openSections initialiser (data(), before this instance
     // has $route-derived computeds available to reuse) and currentSectionType.
     sectionTypeForRoute(route) {
        const section = SECTIONS.find(s => s.route === route.params.type);
        return section ? section.type : null;
     },

     // Map a section type to the list items it should show in the sidebar.
     // Profile items carry an 'active' flag to drive the coloured dot indicator.
     itemsFor(type) {
        if (type === 'user')    return this.users.map(u => ({ id: u.username, label: u.username }));
        if (type === 'role')    return this.roles.map(r => ({ id: r.name,     label: r.name }));
        if (type === 'profile') return this.profiles.map(p => ({ id: p.id, label: p.name || p.id, active: p.active }));
        return [];
     },

     isSelected(type, id) {
        return this.selected.type === type && this.selected.id === id;
     },

     // Select an item: commit the selection to Vuex AND push the corresponding
     // route so the URL is bookmarkable and the browser back button works.
     // App.vue's $route watcher will also call setSelected via updateStateFromRoute,
     // but that is idempotent (same value, mode: 'view') so the duplicate is harmless.
     selectItem(type, id) {
        this.$store.commit('admin/setSelected', { type, id, mode: 'view' });
        const section = SECTIONS.find(s => s.type === type);
        this.$router.push(`/admin/${section.route}/${encodeURIComponent(id)}`).catch(() => {});
     },

     // onSelect (close the drawer, then run the action) comes from the
     // sidebarDrawerSelect mixin (components/mixins/index.js) - shared with
     // Sidebar.vue.
  },

  watch: {
     // Collapses back down to just the section the route just navigated to
     // (e.g. clicking from a Role over to a Profile) - fires only when this
     // actually changes, so a section opened by hand while browsing (or the
     // one being navigated within, e.g. Role A to Role B) isn't fought.
     // A route with no section of its own (the bare /admin placeholder,
     // Account) resolves to null here and is deliberately left alone rather
     // than collapsing everything.
     currentSectionType(type) {
        if (type) this.openSections = [type];
     },
  },
});
</script>

<style lang="scss" scoped>
   .sb-section-heading {
      margin-top: 8px;
   }

   // A plain span rather than <v-list-item-title> - it holds both the
   // label and the expand/collapse caret (below) on one line, styled here
   // directly rather than via the row's own title styling.
   .sb-title-row {
      font-size: 11px;
      font-weight: 700;
      letter-spacing: 0.07em;
      text-transform: uppercase;
   }

   .sb-add {
      font-size: 11.5px;
      font-weight: 600;
      color: rgb(var(--v-theme-primary));

      &:hover {
         text-decoration: underline;
      }
   }

   // Only sections matching the current admin route start open (see
   // AdminSidebar's openSections/currentSectionType) - this is what shows a
   // closed section is collapsed, not empty, and clickable to expand. Sits
   // inside .sb-title-row (right after the label text), not the row's
   // #append slot alongside "+ New" - the far end of the row is shared with
   // that fixed-position link, too far from the label it reflects to read
   // as its state indicator.
   .sb-caret {
      margin-left: 4px;
      vertical-align: middle;
      color: rgb(var(--v-theme-ink-soft));
      transition: transform 0.2s ease;
   }

   .sb-caret--open {
      transform: rotate(90deg);
   }

   // Same .sidebar-dot shape (index.scss) every other sidebar list uses -
   // was previously its own unicode "●" glyph here, a slightly different
   // shape/size than the CSS-drawn circle Users/Roles/devtainers now share.
   .dot-active   { background: rgb(var(--v-theme-granted)); }
   .dot-inactive { background: rgb(var(--v-theme-neutral)); }

   .new-item :deep(.v-list-item-title) {
      color: rgb(var(--v-theme-accent));
      font-style: italic;
   }

   .loading-item :deep(.v-list-item-title) {
      color: rgb(var(--v-theme-ink-soft));
      font-style: italic;
   }
</style>
