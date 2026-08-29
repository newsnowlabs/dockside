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
   // Stage 2 of docs/plans/vue2-vue3-migration.md (dockside-admin repo): Vue 3
   // + @vue/compat running in MODE 2, not native Vue 3 - this is the "soft
   // landing" the whole app runs on until Stage 4's cutover. MODE 2 makes
   // @vue/compat behave like Vue 2 by default (global Vue.use/Vue.component,
   // legacy $listeners/$children, v-model default prop/event names, ...),
   // logging a runtime deprecation warning per legacy feature actually hit
   // instead of breaking outright - which is what lets bootstrap-vue (a real
   // Vue-2-internals library, not compat-aware) keep working unmodified. The
   // 'vue' -> '@vue/compat' alias below is bundler-level only: the real `vue`
   // package stays installed (and pinned to the exact version @vue/compat
   // requires - see package.json) purely so npm's own peer-dependency
   // resolution for vuex/vue-router/etc. is satisfied; nothing actually
   // imports from it directly.
   plugins: [vue({
      template: {
         compilerOptions: {
            compatConfig: { MODE: 2 },
            // Stage 2 landed on 'preserve' here as a stopgap: Vue 3's
            // compiler default ('condense') strips inter-element template
            // whitespace containing a newline entirely, rather than
            // collapsing it to one space the way the old webpack/vue-loader
            // pipeline effectively did, and bootstrap-vue-era markup relied
            // on exactly that whitespace for visual gaps (a run of
            // <b-button>s, one per line, with no explicit margin classes
            // between them). Stage 3 (docs/plans/vue2-vue3-migration.md,
            // dockside-admin repo) replaced every such spot with a real
            // flex+gap wrapper as each file converted (see e.g. Container.vue's
            // .action-buttons, Header.vue's .nav-links) rather than carrying
            // the workaround forward - back to Vue 3's own default now that
            // audit is done; whitespace-only text nodes between elements are
            // condensed/removed the normal way again.
         },
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
         // The specific dist file, not the bare '@vue/compat' specifier:
         // @vue/compat's package.json exports map lists a 'module' condition
         // (-> the runtime-only vue.runtime.esm-bundler.js) before its
         // 'import' condition (-> this, the full compiler+runtime build) -
         // Vite's resolver matches 'module' first, silently handing us the
         // runtime-only build even though this alias's whole point is the
         // compiler-included one (see index.js's root `template:` option,
         // which needs runtime template compilation to work at all).
         'vue': '@vue/compat/dist/vue.esm-bundler.js',
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
