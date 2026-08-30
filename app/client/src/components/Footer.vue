<template>
   <v-footer color="surface-alt" app class="app-footer">
      <div class="footer-links">
         <span class="footer-item first">Dockside {{ version }}</span>
         <span class="sep d-none d-md-inline">|</span>
         <span class="footer-item d-none d-md-inline">An open-source project by NewsNow Labs</span>
         <span class="sep d-none d-md-inline">|</span>
         <router-link to="/docs" class="footer-item">Docs</router-link>
         <span class="sep d-none d-md-inline">|</span>
         <router-link to="/docksideio" class="footer-item">Dockside.io</router-link>
         <span class="sep d-none d-md-inline">|</span>
         <router-link to="/dockside-github" class="footer-item">GitHub</router-link>
         <span class="sep d-none d-md-inline">|</span>
         <router-link to="/newsnow" class="footer-item">NewsNow</router-link>
      </div>
   </v-footer>
</template>

<script>
import { defineComponent } from 'vue';

import { routing } from '@/components/mixins';

export default defineComponent({
  name: 'Footer',

  data() {
     return {
        version: window.dockside.version
     };
  },

  mixins: [routing],
});
</script>

<style lang="scss" scoped>
   .footer-links {
      display: flex;
      flex-wrap: wrap;
      align-items: center;
      gap: 0.4rem;
      width: 100%;
      color: rgb(var(--v-theme-ink));
      font-size: 0.85rem;
   }

   .footer-item {
      color: rgb(var(--v-theme-ink));
      text-decoration: none;

      &:hover {
         color: rgb(var(--v-theme-accent));
      }
   }

   .first {
      font-weight: bold;
   }

   .sep {
      color: rgb(var(--v-theme-ink-soft));
   }
</style>
