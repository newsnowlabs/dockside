import { defineConfig } from 'vite';
import vue from '@vitejs/plugin-vue';
import vuetify, { transformAssetUrls } from 'vite-plugin-vuetify';
import path from 'path';

// No index.html: `app/server/lib/App.pm` serves the SPA shell itself and
// references dist/main.{js,css} by fixed name (see App.pm's /assets/main.js
// and /assets/main.css routes) — those two filenames are a contract with the
// server, not just build output, so entryFileNames/assetFileNames below must
// keep producing exactly them. cssCodeSplit keeps CSS output to the single
// main.css file that shape requires, regardless of how many JS chunks Rollup
// produces (see README's "Build outputs").
//
// JS output is *not* forced to a single chunk any more (review.md #10):
// format is Rollup's default ES-module output, so `import()` call sites
// (App.vue's lazy AdminMain, see that file's own comment) become genuine
// separate chunks under dist/assets/, fetched only when actually navigated
// to, instead of every visitor downloading the whole admin panel in one
// inlined main.js. This is why App.pm's <script> tag needed
// type="module" - Rollup's iife/umd formats used before this can't do
// code-splitting at all ("UMD and IIFE output formats are not supported for
// code-splitting builds"), which is what inlineDynamicImports previously
// papered over by forcing every dynamic import() back inline.
export default defineConfig({
   // Pure Vue 3 as of Stage 4 (docs/plans/vue2-vue3-migration.md,
   // dockside-admin repo) - no @vue/compat, no compatConfig. Stages 2-3 ran
   // this under @vue/compat MODE 2 (global Vue.use/Vue.component, legacy
   // $listeners/$children, v-model default prop/event names, ...) as the
   // "soft landing" that let bootstrap-vue keep working unmodified while it
   // was migrated off component-by-component; that scaffolding is gone now
   // there's nothing left that needs it (verified live pre-cutover: zero
   // compat deprecation warnings anywhere in the app, meaning nothing was
   // silently still relying on it).
   plugins: [vue({
      template: {
         // Lets Vuetify's own asset-handling (e.g. <v-img src="...">) resolve
         // relative src/srcset paths the same way plain <img> tags do here -
         // see vite-plugin-vuetify's README ("Image loading").
         transformAssetUrls,
      },
   }),
   // Stage 3 of docs/plans/vue2-vue3-migration.md (dockside-admin repo):
   // Vuetify 3 replacing bootstrap-vue app-wide. autoImport scans each SFC's
   // template for Vuetify component/directive names actually used and injects
   // only those imports - no need to hand-import every v-* component. This is
   // a compile-time source transform (adds import statements before Rollup
   // ever runs), so it's unaffected by this app's output-bundling shape
   // (cssCodeSplit, entryFileNames/chunkFileNames below) - those are
   // output-bundling settings, not import resolution.
   vuetify({ autoImport: true })],
   resolve: {
      // Source imports `.vue` files without an extension throughout (e.g.
      // `import Header from '@/components/Header'`), matching the old webpack
      // config's resolve.extensions list — Vite's own default omits '.vue'.
      extensions: ['.mjs', '.js', '.mts', '.ts', '.jsx', '.tsx', '.json', '.vue'],
      alias: {
         '@': path.resolve(__dirname, 'src'),
         // The full compiler+runtime dist file, not the bare 'vue' specifier:
         // 'vue''s own package.json exports map resolves a bare import to
         // dist/vue.runtime.esm-bundler.js (runtime only, no template
         // compiler) - fine for every .vue SFC, which @vitejs/plugin-vue
         // precompiles to a render function ahead of time, but index.js's
         // root app instance is defined with a plain string `template:`
         // option (just '<router-view></router-view>', see that file's own
         // comment for why), which needs the *runtime* template compiler to
         // turn into a render function. This alias is the same fix Stage 2
         // needed for @vue/compat's own build (see that stage's history in
         // docs/plans/vue2-vue3-migration.md, dockside-admin repo) applied to
         // plain 'vue' now compat is gone.
         'vue': 'vue/dist/vue.esm-bundler.js',
      },
   },
   build: {
      outDir: 'dist',
      emptyOutDir: true,
      sourcemap: true,
      cssCodeSplit: false,
      rollupOptions: {
         input: path.resolve(__dirname, 'src/index.js'),
         output: {
            // Rollup's default ES-module output ('export ...'/'import(...)')
            // is what makes code-splitting possible at all - iife/umd (the
            // old format here) can only ever emit a single chunk, which is
            // why every dynamic import() used to get forced back inline via
            // inlineDynamicImports (review.md #10: that meant the whole
            // admin panel shipped to every visitor). An ES-module bundle
            // needs a module script, so app-server's <script> tag for
            // main.js now carries type="module" to match (see that file's
            // own comment).
            //
            // entryFileNames sits under 'assets/' too, not dist-root
            // 'main.js' as before: a dynamic import() chunk's runtime import
            // path is resolved by the browser relative to the *URL* of the
            // module that imports it, not relative to dist/ on disk. App.pm
            // serves dist/main.js at URL /assets/main.js (a deliberate
            // naming contract, not a path one - see this file's top
            // comment), so once main.js started actually importing a chunk
            // (AdminMain, above), a chunk path written relative to dist-root
            // (plain 'assets/[name]-[hash].js') resolved in the browser
            // relative to /assets/main.js's own URL instead, i.e.
            // /assets/assets/[name]-[hash].js - confirmed live via Playwright
            // ("Failed to fetch dynamically imported module"). Emitting
            // main.js under dist/assets/ too makes its on-disk location
            // match its URL, so Rollup's dist-relative chunk path and the
            // browser's URL-relative resolution agree; app-server's
            // '/assets/main.js' route reads from the same new path (see that
            // file's own comment).
            entryFileNames: 'assets/main.js',
            chunkFileNames: 'assets/[name]-[hash].js',
            assetFileNames: (assetInfo) => (
               assetInfo.names?.includes('style.css') ? 'main.css' : 'assets/[name]-[hash][extname]'
            ),
         },
      },
   },
});
