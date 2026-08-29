import { defineConfig } from 'vite';
import vue from '@vitejs/plugin-vue';
import vuetify, { transformAssetUrls } from 'vite-plugin-vuetify';
import path from 'path';

// No index.html: `app/server/lib/App.pm` serves the SPA shell itself and
// references dist/main.{js,css} by fixed name (see App.pm's /assets/main.js
// and /assets/main.css routes) — those two filenames are a contract with the
// server, not just build output, so entryFileNames/assetFileNames below must
// keep producing exactly them. cssCodeSplit + inlineDynamicImports keep the
// output to a single JS file and a single CSS file, same shape webpack
// produced (main.js, main.css - see README's "Build outputs").
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
   // ever runs), so it's unaffected by this app's unusual single-file output
   // shape (format: 'iife', cssCodeSplit: false, inlineDynamicImports below) -
   // those are output-bundling settings, not import resolution.
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
            // The server's own <script> tag (app-server:311) has no
            // type="module" - it's a plain classic-script include, same as
            // webpack's old UMD-ish default output. Vite/Rollup default to
            // ES-module output ('export ...'), which a classic script tag
            // can't parse ("Unexpected token 'export'"), so pin the format
            // to a self-contained IIFE instead.
            format: 'iife',
            inlineDynamicImports: true,
            entryFileNames: 'main.js',
            assetFileNames: (assetInfo) => (
               assetInfo.names?.includes('style.css') ? 'main.css' : 'assets/[name]-[hash][extname]'
            ),
         },
      },
   },
});
