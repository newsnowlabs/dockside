// Vuetify 3 instance, configured once here and installed globally in
// index.js (via a real app.use() - Vuetify is genuinely Vue-3-native, unlike
// bootstrap-vue, which needed the compat global Vue.use() path; see index.js
// for that history). Stage 3 of docs/plans/vue2-vue3-migration.md
// (dockside-admin repo): replaces bootstrap-vue app-wide.
//
// Theme carries forward the bootstrap-vue era's custom $started/$stopped
// colors (see index.scss's old $theme-colors map) as named Vuetify theme
// colors, same hex values, still referenced the same way (e.g. a running
// container's badge used color="started").
import 'vuetify/styles';
import { aliases, mdi } from 'vuetify/iconsets/mdi-svg';
import { createVuetify } from 'vuetify';

export default createVuetify({
   // SVG icon set, not @mdi/font: only ~5 distinct mdi-* icon names are used
   // app-wide (grep-confirmed), but @mdi/font's CSS+font-file bundle has no
   // per-icon granularity - loading it unconditionally cost every page load
   // a ~700KB stylesheet plus hundreds of KB to over 1MB of font assets for
   // those 5 icons. vuetify/iconsets/mdi-svg costs nothing extra for
   // Vuetify's own internal icons (checkboxes, dropdown chevrons, close
   // buttons, ...) - its aliases are inlined SVG path data, not an @mdi/js
   // import - so only the app's own explicit icon usages (Header.vue,
   // BottomNav.vue, SSHInfo.vue) need real @mdi/js imports, each ~100-300
   // bytes, tree-shaken to just the icons actually referenced.
   icons: {
      defaultSet: 'mdi',
      aliases,
      sets: { mdi },
   },
   theme: {
      defaultTheme: 'light',
      themes: {
         light: {
            colors: {
               primary: '#337ab7', // was bootstrap's $started, reused as primary too
               started: '#337ab7',
               stopped: '#f8f9fa',
            },
         },
      },
   },
   defaults: {
      // v-list-group's default per-nesting-level indent (its whole purpose
      // is showing tree depth via padding) isn't wanted anywhere in this
      // app - the one current user (AdminSidebar.vue's USERS/ROLES/PROFILES
      // sections) already reads as a heading via its own bold small-caps
      // styling, so the indent was just unused dead space (confirmed live:
      // ~140px). Set once here, as a component default, rather than a
      // `fluid` prop repeated on every v-list-group - the same reasoning as
      // App.vue's .page-content gutter and index.scss's alert/code
      // overrides: a per-instance prop is one a future v-list-group can
      // just as easily forget, the same way AdminMain.vue's own copy of
      // Main.vue's gutter padding was dropped without anyone noticing.
      VListGroup: {
         fluid: true,
      },
   },
});
