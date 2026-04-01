<template>
   <b-col md="3" lg="2" class="sidebar admin-sidebar">
      <b-nav vertical class="nav-sidebar">

         <template v-for="section in visibleSections">
            <!-- Section heading (click to collapse) -->
            <b-nav-text
               :key="section.type + '-heading'"
               class="heading"
               @click="toggleSection(section.type)"
            >
               {{ section.label }}
               <span class="section-toggle">{{ collapsed[section.type] ? '▸' : '▾' }}</span>
            </b-nav-text>

            <b-collapse
               :key="section.type + '-collapse'"
               :visible="!collapsed[section.type]"
            >
               <!-- Loading placeholder -->
               <b-nav-item v-if="loading" disabled class="loading-item">
                  Loading…
               </b-nav-item>

               <!-- Items -->
               <template v-else>
                  <b-nav-item
                     v-for="item in itemsFor(section.type)"
                     :key="item.id"
                     :class="{ selected: isSelected(section.type, item.id) }"
                     @click="selectItem(section.type, item.id)"
                  >
                     <span v-if="section.type === 'profile'" class="profile-dot" :class="item.active ? 'dot-active' : 'dot-inactive'" title="active/inactive">●</span>
                     {{ item.label }}
                  </b-nav-item>

                  <!-- New item link -->
                  <b-nav-item
                     :key="section.type + '-new'"
                     class="new-item"
                     @click="selectItem(section.type, 'new')"
                  >+ New {{ section.singular }}</b-nav-item>
               </template>
            </b-collapse>
         </template>

      </b-nav>
   </b-col>
</template>

<script>
   import { mapState, mapGetters } from 'vuex';

   const SECTIONS = [
      { type: 'user',    label: 'USERS',    singular: 'user'    },
      { type: 'role',    label: 'ROLES',    singular: 'role'    },
      { type: 'profile', label: 'PROFILES', singular: 'profile' },
   ];

   export default {
      name: 'AdminSidebar',

      data() {
         return {
            collapsed: { user: false, role: false, profile: false },
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

         toggleSection(type) {
            this.$set(this.collapsed, type, !this.collapsed[type]);
         },
      },
   };
</script>

<style lang="scss" scoped>
   .admin-sidebar {
      display: none;
   }

   @media (min-width: 768px) {
      .admin-sidebar {
         display: block;
         position: fixed;
         top: 56px;
         bottom: 0;
         padding: 20px 0;
         overflow-y: auto;
         background-color: #f5f5f5;
         border-right: 1px solid #eee;
      }
   }

   .nav-item {
      a {
         padding-right: 20px;
         padding-left: 20px;
         white-space: nowrap;
         overflow: hidden;
         text-overflow: ellipsis;
      }

      &.selected a {
         font-weight: bold;
      }

      &.new-item a {
         color: #5c9bd1;
         font-style: italic;
      }

      &.loading-item a {
         color: #aaa;
         font-style: italic;
      }
   }

   .navbar-text.heading {
      font-weight: bold;
      padding-left: 20px;
      padding-right: 20px;
      cursor: pointer;
      user-select: none;
      display: flex;
      justify-content: space-between;
      align-items: center;
      margin-top: 8px;

      &:hover {
         color: #337ab7;
      }
   }

   .section-toggle {
      font-size: 0.7rem;
      color: #999;
      margin-left: 4px;
   }

   .profile-dot {
      font-size: 0.6rem;
      margin-right: 3px;
      vertical-align: middle;

      &.dot-active   { color: #28a745; }
      &.dot-inactive { color: #aaa;    }
   }
</style>
