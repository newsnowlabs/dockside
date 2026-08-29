import { defineConfig, mergeConfig } from 'vitest/config';
import viteConfig from './vite.config.js';

// Reuses vite.config.js's plugin/resolve.alias/extensions (see that file's
// own comments, notably the 'vue' alias to the full compiler+runtime build)
// so tests see the same module resolution the real build does. The build.*
// options merge in too but are inert here; vitest doesn't use Vite's
// production build pipeline.
export default mergeConfig(viteConfig, defineConfig({
   test: {
      environment: 'jsdom',
      setupFiles: ['./test/setup.js'],
      include: ['test/**/*.spec.js'],
      // Stage 3 of docs/plans/vue2-vue3-migration.md (dockside-admin repo):
      // Vuetify components each import their own .css file directly (e.g.
      // VBtn.js: import "./VBtn.css") - fine for Vite's real build/dev
      // pipeline, which intercepts .css imports, but Vitest's default
      // dependency handling resolves node_modules packages via plain Node
      // ESM resolution rather than routing them through that same
      // interception, so the .css import hit Node's loader directly and
      // threw "Unknown file extension '.css'" - confirmed live, the first
      // spec file mounting any component that pulls in Vuetify (Container,
      // ProfileDetail, UserDetail - anything using the new ChoiceInput.vue)
      // failed to even load. server.deps.inline routes the named packages
      // through Vite's transform pipeline instead, same as the real build.
      server: {
         deps: {
            inline: ['vuetify'],
         },
      },
   },
}));
