import { defineConfig, mergeConfig } from 'vitest/config';
import { resolve } from 'path';
import viteConfig from './vite.config.js';

// Reuses vite.config.js's plugin/resolve.alias/extensions (Vue 3 + @vue/compat
// MODE 2 - see that file's own comments) so tests see the same module
// resolution the real build does. The build.* options merge in too but are
// inert here; vitest doesn't use Vite's production build pipeline.
export default mergeConfig(viteConfig, defineConfig({
   resolve: {
      alias: {
         // Vitest's own resolver (distinct from Vite's production build
         // pipeline, despite sharing this config via mergeConfig) picks
         // bootstrap-vue's raw src/ over its esm/ dist build for reasons not
         // fully tracked down - confirmed live via a thrown error inside
         // bootstrap-vue/src/utils/config-set.js, a file that plays no part
         // in the real production bundle at all. Force the same esm/ entry
         // point production actually uses.
         'bootstrap-vue': resolve(__dirname, 'node_modules/bootstrap-vue/esm/index.js'),
      },
   },
   test: {
      environment: 'jsdom',
      setupFiles: ['./test/setup.js'],
      include: ['test/**/*.spec.js'],
   },
}));
