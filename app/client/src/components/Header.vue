<template>
   <v-app-bar color="chrome" density="comfortable">
      <v-app-bar-nav-icon class="d-md-none" @click="$emit('toggle-nav')" aria-label="Toggle navigation"></v-app-bar-nav-icon>

      <v-toolbar-title class="app-brand" @click="goHome(false)"><Dockside colour="white"/></v-toolbar-title>

      <v-spacer></v-spacer>

      <div class="d-none d-md-flex align-center nav-links">
         <v-select v-show="!isSelected && !isAdminRoute && !isAccountRoute"
            v-model="containersFilter"
            :items="containersFilterItems"
            hide-details
            class="containers-filter" aria-label="Filter containers"
         ></v-select>

         <v-btn variant="text" to="/" exact :class="{ 'nav-btn--active': isContainerSection }">
            <v-icon start :icon="mdiHome"></v-icon> Containers
         </v-btn>

         <v-btn variant="text" v-show="user.permissions.actions.createContainerReservation"
            :class="{ 'nav-btn--active': isPrelaunchMode }" @click="goToContainer('new', 'prelaunch')">
            <v-icon start :icon="mdiPlusCircle"></v-icon> Launch
         </v-btn>

         <v-btn variant="text" v-show="canAccessAdmin" to="/admin" :class="{ 'nav-btn--active': isAdminRoute }">
            <v-icon start :icon="mdiCog"></v-icon> Admin
         </v-btn>

         <v-btn variant="text" to="/account" :class="{ 'nav-btn--active': isAccountRoute }" :title="'Account settings for ' + user.username">
            <v-icon start :icon="mdiAccountCircle"></v-icon> {{ displayName }}
         </v-btn>
      </div>

      <!-- Outside .nav-links (d-md-flex-gated): visible at every viewport
           width, mobile included, unlike the rest of the desktop nav (mobile
           uses BottomNav.vue for primary navigation instead). -->
      <v-btn variant="text" icon @click="cycleThemeMode" :title="themeModeTitle" :aria-label="themeModeTitle">
         <v-icon :icon="themeModeIcon"></v-icon>
      </v-btn>
   </v-app-bar>
</template>

<script>
import { defineComponent } from 'vue';
import { mdiWeatherSunny, mdiWeatherNight, mdiBrightnessAuto } from '@mdi/js';

import { mapGetters } from 'vuex';
import { routing, routePermissions, navIcons } from '@/components/mixins';
import Dockside from '@/components/Dockside';
import { currentThemeMode, cycleThemeMode } from '@/plugins/vuetify';

const CONTAINERS_FILTER_ITEMS = [{title: 'Shared', value: 'shared'}, {title: 'All', value: 'all'}];

// One icon + title per mode currentThemeMode() can report - cycled by
// cycleThemeMode() (plugins/vuetify.js), light -> dark -> system -> light ...
const THEME_MODE_DISPLAY = {
   light:  { icon: mdiWeatherSunny,  title: 'Theme: Light (click for Dark)' },
   dark:   { icon: mdiWeatherNight,  title: 'Theme: Dark (click for System)' },
   system: { icon: mdiBrightnessAuto, title: 'Theme: System (click for Light)' },
};

export default defineComponent({
  name: 'Header',
  emits: ['toggle-nav'],

  components: {
     Dockside
  },

  computed: {
     ...mapGetters(['isSelected', 'isPrelaunchMode']),
     containersFilterItems() {
        return CONTAINERS_FILTER_ITEMS;
     },
     themeModeIcon() {
        return THEME_MODE_DISPLAY[currentThemeMode()].icon;
     },
     themeModeTitle() {
        return THEME_MODE_DISPLAY[currentThemeMode()].title;
     },
     user() {
        return this.$store.state.account.currentUser;
     },
     displayName() {
        const { name, email, username } = this.user;
        // Prefer first name, then surname — both come from the same 'name' field.
        // A multi-word name yields the first word; a single-word name is treated as
        // a surname and used directly.
        if (name) {
           const words = name.trim().split(/\s+/).filter(Boolean);
           if (words.length) return words[0];
        }
        if (email) {
           // Slightly obfuscate: keep first 1–3 chars of local part + … + @domain
           return email.replace(/^(.{1,3})[^@]*(@.+)$/, '$1…$2');
        }
        return username;
     },
     containersFilter: {
        get() {
           return this.$store.state.containersFilter;
        },
        set(filter) {
           this.$store.dispatch('updateContainersFilter', filter);
           switch (filter) {
              case 'all':
              case 'own': {
                 this.$router.push({ path: '/', query: Object.assign({}, this.$route.query, { cf: filter }) });
                 break;
              }
              case 'shared': {
                 const query = Object.assign({}, this.$route.query);
                 // Delete cf param rather than set to 'all'.
                 delete query.cf;
                 this.$router.push({ path: '/', query });
                 break;
              }
           }
        }
     }
  },

  methods: {
     refresh() {
        this.$store.dispatch('updateContainers', 1);
     },
     // Templates only see `this`-bound methods, not the enclosing module's
     // plain imports - this just forwards to plugins/vuetify.js's own
     // cycleThemeMode, which owns the actual mode/localStorage/theme state.
     cycleThemeMode,
  },

  mixins: [routing, routePermissions, navIcons],
});
</script>

<style lang="scss" scoped>
   // Explicit gap, not template whitespace - Vue 3's compiler default
   // ('condense') collapses inter-node whitespace containing a newline
   // unpredictably.
   .nav-links {
      gap: 4px;
   }

   .app-brand {
      cursor: pointer;
      flex: 0 0 auto;
      font-size: 28px;
   }

   .containers-filter {
      max-width: 130px;
      margin-right: 12px;
   }

   .nav-btn--active {
      border-bottom: 2px solid rgba(255, 255, 255, 0.65);
   }
</style>
