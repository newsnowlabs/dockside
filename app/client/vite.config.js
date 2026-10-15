import { defineConfig } from 'vite';
import vue from '@vitejs/plugin-vue';
import vuetify, { transformAssetUrls } from 'vite-plugin-vuetify';
import path from 'path';

// No index.html: the server writes the SPA's HTML page itself. Its contract
// with this build is dist/manifest.json, Vite's build manifest: the server
// finds the one chunk marked isEntry and writes a <script type="module"> for
// its `file` and a stylesheet link for each name in its `css` list. Every
// built file - the entry, lazy-loaded chunks such as the admin screens, their
// stylesheets, source maps, fonts - goes to dist/assets/<name>-<hash>.<ext>,
// which the server serves at /assets/<file>, before login, with a long
// immutable cache lifetime: a file's name changes whenever its content does.
// A lazy-loaded chunk imports the entry by its hashed name, the same URL the
// page's script tag uses, so the browser loads the entry once.
//
// JS output is Rollup's default ES-module format, so `import()` call sites
// (App.vue's lazy AdminMain, see that file's own comment) become genuine
// separate chunks under dist/assets/, fetched only when actually navigated
// to, so a visitor who never opens the admin screens never downloads them.
// The format must stay ES modules: Rollup's iife/umd formats can't
// code-split at all ("UMD and IIFE output formats are not supported for
// code-splitting builds").
export default defineConfig({
   // Components register locally via imports; there is no global component
   // registration.
   plugins: [vue({
      template: {
         // Lets Vuetify's own asset-handling (e.g. <v-img src="...">) resolve
         // relative src/srcset paths the same way plain <img> tags do here -
         // see vite-plugin-vuetify's README ("Image loading").
         transformAssetUrls,
      },
   }),
   // Vuetify 3 provides the app's UI components. autoImport scans each SFC's
   // template for Vuetify component/directive names actually used and injects
   // only those imports - no need to hand-import every v-* component. This is
   // a compile-time source transform (adds import statements before Rollup
   // ever runs), so it's unaffected by this app's output-bundling shape
   // (entryFileNames/chunkFileNames below) - those are output-bundling
   // settings, not import resolution.
   // styles.configFile compiles Vuetify's own component CSS from its Sass
   // source instead of importing precompiled CSS, so src/settings.scss's
   // $body-font-family override (IBM Plex Sans) reaches every Vuetify
   // component selector that sets it directly, not just plain HTML tags.
   vuetify({ autoImport: true, styles: { configFile: 'src/settings.scss' } })],
   resolve: {
      // Source imports `.vue` files without an extension throughout (e.g.
      // `import Header from '@/components/Header'`), so '.vue' is listed
      // here — Vite's own default omits it.
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
         // turn into a render function.
         'vue': 'vue/dist/vue.esm-bundler.js',
      },
   },
   build: {
      outDir: 'dist',
      emptyOutDir: true,
      sourcemap: true,
      // Pinned to dist/manifest.json, the path the server reads: Vite's own
      // default location for the manifest has differed between versions.
      // dist/ itself is not served; only dist/assets/ is.
      manifest: 'manifest.json',
      rollupOptions: {
         input: path.resolve(__dirname, 'src/index.js'),
         output: {
            // Rollup's default ES-module output ('export ...'/'import(...)')
            // is what makes code-splitting possible at all (see this file's
            // top comment). An ES-module bundle needs a module script, so
            // the server must load the entry with <script type="module">.
            //
            // The entry must stay under 'assets/' with the chunks, not at the
            // dist root: the browser resolves a dynamic import() chunk's
            // path relative to the *URL* of the module that imports it, not
            // relative to dist/ on disk. The server serves dist/assets/ at
            // /assets/, so an entry under dist/assets/ has an on-disk place
            // that matches its URL. A dist-root entry would get chunk paths
            // written relative to the dist root ('assets/[name]-[hash].js'),
            // which the browser would resolve against the entry's /assets/
            // URL to /assets/assets/[name]-[hash].js and fail ("Failed to
            // fetch dynamically imported module").
            entryFileNames: 'assets/[name]-[hash].js',
            chunkFileNames: 'assets/[name]-[hash].js',
            assetFileNames: 'assets/[name]-[hash][extname]',
         },
      },
   },
});
