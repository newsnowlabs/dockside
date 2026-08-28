import { defineConfig } from 'vite';
import vue2 from '@vitejs/plugin-vue2';
import path from 'path';

// No index.html: `app/server/lib/App.pm` serves the SPA shell itself and
// references dist/main.{js,css} by fixed name (see App.pm's /assets/main.js
// and /assets/main.css routes) — those two filenames are a contract with the
// server, not just build output, so entryFileNames/assetFileNames below must
// keep producing exactly them. cssCodeSplit + inlineDynamicImports keep the
// output to a single JS file and a single CSS file, same shape webpack
// produced (main.js, main.css - see README's "Build outputs").
export default defineConfig({
   plugins: [vue2()],
   resolve: {
      // Source imports `.vue` files without an extension throughout (e.g.
      // `import Header from '@/components/Header'`), matching the old webpack
      // config's resolve.extensions list — Vite's own default omits '.vue'.
      extensions: ['.mjs', '.js', '.mts', '.ts', '.jsx', '.tsx', '.json', '.vue'],
      alias: {
         '@': path.resolve(__dirname, 'src'),
         // Full compiler+runtime build, not runtime-only: index.js's root
         // Vue instance (`new Vue({router, store}).$mount('#app')`) has no
         // template/render option of its own - it compiles the pre-existing
         // `<router-view>` markup already in #app (see App.pm's page HTML)
         // at runtime, which the runtime-only build can't do. .vue SFCs
         // themselves are still precompiled by @vitejs/plugin-vue2; this
         // alias only matters for that one root-mount case. Mirrors the old
         // webpack 'vue$' alias exactly (same vue.esm.js target).
         'vue': 'vue/dist/vue.esm.js',
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
