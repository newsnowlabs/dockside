<template>
   <!-- Stage 3 of docs/plans/vue2-vue3-migration.md (dockside-admin repo): one
        v-navigation-drawer replaces the old desktop b-col + mobile b-sidebar
        pair (see Sidebar.vue's own comment for the same pattern and the
        modelValue/COMPONENT_V_MODEL reasoning). Each section is a
        v-list-group - Vuetify's own collapsible-header primitive - rather
        than the old manual b-collapse + hand-rolled ▸/▾ toggle. Its default
        per-nesting-level indent is turned off app-wide (plugins/vuetify.js's
        VListGroup default, not a `fluid` prop here) - see that file's own
        comment for why. -->
   <v-navigation-drawer
      :model-value="modelValue"
      @update:model-value="$emit('update:modelValue', $event)"
      :permanent="$vuetify.display.mdAndUp"
      width="260"
   >
      <v-list nav density="compact" v-model:opened="openSections">
         <v-list-group v-for="section in visibleSections" :key="section.type" :value="section.type">
            <template #activator="{ props: activatorProps }">
               <v-list-item v-bind="activatorProps" class="sb-section-heading">
                  <v-list-item-title>{{ section.label }}</v-list-item-title>
                  <template #append>
                     <span class="sb-add" @click.stop="onSelect(section.type, 'new')">+ New</span>
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
                  @click="onSelect(section.type, item.id)"
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

import { mapState, mapGetters } from 'vuex';

const SECTIONS = [
   { type: 'user',    label: 'USERS',    singular: 'user'    },
   { type: 'role',    label: 'ROLES',    singular: 'role'    },
   { type: 'profile', label: 'PROFILES', singular: 'profile' },
];

export default defineComponent({
  name: 'AdminSidebar',
  props: {
     modelValue: { type: Boolean, default: false },
  },
  emits: ['update:modelValue'],

  data() {
     return {
        // All sections start open (v-list-group defaults closed otherwise) -
        // harmless for a section visibleSections later filters out, v-list
        // just ignores an opened-array entry it has no matching group for.
        openSections: ['user', 'role', 'profile'],
     };
  },

  computed: {
     ...mapState('admin', ['users', 'roles', 'profiles', 'selected', 'loading']),

     ...mapGetters('admin', ['isEditMode']),

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
        const typeToRoute = { user: 'users', role: 'roles', profile: 'profiles' };
        this.$router.push(`/admin/${typeToRoute[type]}/${encodeURIComponent(id)}`).catch(() => {});
     },

     // Close the drawer (mobile/temporary only), then select - one path
     // instead of the old selectItem/onMobileSelect split the two markup
     // copies needed. The mdAndUp guard matters: closing unconditionally
     // looked harmless (surely a permanent drawer just ignores its own
     // modelValue?) but doesn't - confirmed live, every click collapsed the
     // md+ permanent drawer too, because Vuetify's internal "re-open when
     // :permanent becomes true" watcher only fires on *permanent itself*
     // changing, not on modelValue being set false while permanent stays
     // constantly true - see App.vue's drawerOpen comment for the closely
     // related initial-value version of this same gotcha.
     onSelect(type, id) {
        if (!this.$vuetify.display.mdAndUp) this.$emit('update:modelValue', false);
        this.selectItem(type, id);
     },
  },
});
</script>

<style lang="scss" scoped>
   .sb-section-heading {
      margin-top: 8px;

      :deep(.v-list-item-title) {
         font-size: 11px;
         font-weight: 700;
         letter-spacing: 0.07em;
         text-transform: uppercase;
      }
   }

   .sb-add {
      font-size: 11.5px;
      font-weight: 600;
      color: rgb(var(--v-theme-primary));

      &:hover {
         text-decoration: underline;
      }
   }

   // Same .sidebar-dot shape (index.scss) every other sidebar list uses -
   // was previously its own unicode "●" glyph here, a slightly different
   // shape/size than the CSS-drawn circle Users/Roles/devtainers now share.
   .dot-active   { background: #28a745; }
   .dot-inactive { background: #aaa;    }

   .new-item :deep(.v-list-item-title) {
      color: #5c9bd1;
      font-style: italic;
   }

   .loading-item :deep(.v-list-item-title) {
      color: #aaa;
      font-style: italic;
   }
</style>
