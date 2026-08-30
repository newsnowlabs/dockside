// Vuetify 3 instance, configured once here and installed globally in
// index.js (via a real app.use() - Vuetify is genuinely Vue-3-native, unlike
// bootstrap-vue, which needed the compat global Vue.use() path; see index.js
// for that history). Stage 3 of docs/plans/vue2-vue3-migration.md
// (dockside-admin repo): replaces bootstrap-vue app-wide.
import 'vuetify/styles';
import { aliases, mdi } from 'vuetify/iconsets/mdi-svg';
import { createVuetify } from 'vuetify';

// The Devtainer Design System's full light/dark token set. Each is
// registered both as one of Vuetify's own standard theme slots (background,
// surface, primary, error, success - so Vuetify's own components pick the
// right color up automatically) and as a same-named custom color (ink,
// border, accent-soft, etc.) for raw CSS to reference directly via
// rgb(var(--v-theme-<name>)), the same pattern already used for started/
// stopped below.
//
// started/stopped (container running/stopped status, used by Sidebar.vue's
// status dot) are accent/neutral respectively, not independent colors - the
// design doc calls out both explicitly: "Status uses the accent for
// 'running,' not the more obvious green" (started), and neutral's own
// swatch entry is labelled "Stopped / inactive status" (stopped).
function themeColors({ ink, inkSoft, ground, surface, surfaceAlt, border, accent, accentStrong, accentSoft, neutral, neutralSoft, danger, dangerSoft, granted, grantedSoft }) {
   return {
      background: ground,
      surface,
      'surface-variant': surfaceAlt,
      'on-surface-variant': inkSoft,
      primary: accent,
      'primary-darken-1': accentStrong,
      error: danger,
      success: granted,
      started: accent,
      stopped: neutral,
      ink,
      'ink-soft': inkSoft,
      ground,
      'surface-alt': surfaceAlt,
      border,
      accent,
      'accent-strong': accentStrong,
      'accent-soft': accentSoft,
      neutral,
      'neutral-soft': neutralSoft,
      danger,
      'danger-soft': dangerSoft,
      granted,
      'granted-soft': grantedSoft,
   };
}

const LIGHT_COLORS = themeColors({
   ink: '#16212c', inkSoft: '#4b5a6a', ground: '#f4f6f9',
   surface: '#ffffff', surfaceAlt: '#edf1f5', border: '#dde3ea',
   accent: '#2e6da4', accentStrong: '#1f5687', accentSoft: '#dce9f4',
   neutral: '#64748b', neutralSoft: '#e4e8ee',
   danger: '#b3261e', dangerSoft: '#f6dedc',
   granted: '#2f7d4f', grantedSoft: '#e1f2e7',
});

const DARK_COLORS = themeColors({
   ink: '#e7ecf2', inkSoft: '#9fb0c2', ground: '#0f151b',
   surface: '#17212b', surfaceAlt: '#1e2a36', border: '#2b3947',
   accent: '#6fa3d8', accentStrong: '#93bfe8', accentSoft: '#203852',
   neutral: '#93a1b5', neutralSoft: '#26313e',
   danger: '#e5787a', dangerSoft: '#3b2224',
   granted: '#7cc79c', grantedSoft: '#1c3327',
});

// Vuetify's own theme instance already has a real 'system' mode - a
// defaultTheme of 'system' resolves against, and live-follows,
// prefers-color-scheme via its own internal matchMedia listener (see
// theme.isSystem / theme.change() in vuetify/lib/composables/theme.js) - no
// need to reimplement any of that here. THEME_STORAGE_KEY is exported so
// Header.vue's toggle can persist the mode it picks.
export const THEME_STORAGE_KEY = '/dockside/theme';

const vuetify = createVuetify({
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
      // 'system' is a real value Vuetify's own theme instance understands
      // directly (see this file's earlier comment) - no resolving it to a
      // concrete light/dark ourselves.
      defaultTheme: localStorage.getItem(THEME_STORAGE_KEY) || 'system',
      themes: {
         light: { colors: LIGHT_COLORS },
         dark: { colors: DARK_COLORS },
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

// light -> dark -> system -> light ..., matching the 3 icons Header.vue's
// toggle button cycles through. theme.isSystem/theme.name (both real Vue
// refs) are read here rather than tracked in a separate ref of our own -
// they're already the live source of truth Vuetify itself updates.
const NEXT_MODE = { light: 'dark', dark: 'system', system: 'light' };

export function currentThemeMode() {
   return vuetify.theme.isSystem.value ? 'system' : vuetify.theme.name.value;
}

export function cycleThemeMode() {
   const next = NEXT_MODE[currentThemeMode()];
   // theme.change(), not a direct assignment to theme.global.name: the
   // latter is a plain property holding a ref-like Proxy, and assigning to
   // it directly (rather than through Vue's reactive() ref-unwrapping,
   // which only applies when accessed as e.g. this.$vuetify.theme.global.
   // name from inside a component) replaces that Proxy outright instead of
   // updating it - confirmed live: the theme only changed after a full page
   // reload, never on the click itself. change() is Vuetify's own supported
   // API for exactly this.
   vuetify.theme.change(next);
   localStorage.setItem(THEME_STORAGE_KEY, next);
}

export default vuetify;
