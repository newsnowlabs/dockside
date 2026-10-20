import { fileURLToPath, URL } from 'node:url'

import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'
import vueDevTools from 'vite-plugin-vue-devtools'

// DEVTAINER_HOST is set by the image's entrypoint to the host name the app is served at behind
// Dockside's proxy. Behind the proxy the page is HTTPS on port 443, so Vite's live-update socket
// connects there too, and only that host name is accepted. Without it, as with a plain
// `docker run`, any host name is accepted and the socket uses the dev server's own port.
const devtainerHost = process.env.DEVTAINER_HOST

// https://vite.dev/config/
export default defineConfig({
  plugins: [
    vue(),
    vueDevTools(),
  ],
  resolve: {
    alias: {
      '@': fileURLToPath(new URL('./src', import.meta.url)),
    },
  },
  server: {
    host: true,
    port: 5173,
    strictPort: true,
    allowedHosts: devtainerHost ? [devtainerHost] : true,
    hmr: devtainerHost ? { protocol: 'wss', clientPort: 443 } : true,
  },
})
