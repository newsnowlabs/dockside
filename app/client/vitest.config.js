import { defineConfig, mergeConfig } from 'vitest/config';
import viteConfig from './vite.config.js';

// Reuses vite.config.js's resolve.alias/extensions and @vitejs/plugin-vue2 so
// tests see the same module resolution the real build does (in particular the
// 'vue' -> vue/dist/vue.esm.js alias - see vite.config.js's own comment on
// why the compiler+runtime build matters). The build.* options merge in too
// but are inert here; vitest doesn't use Vite's production build pipeline.
export default mergeConfig(viteConfig, defineConfig({
   test: {
      environment: 'jsdom',
      setupFiles: ['./test/setup.js'],
      include: ['test/**/*.spec.js'],
   },
}));
