import react from '@vitejs/plugin-react'
import { defineConfig } from 'vite'

// DEVTAINER_HOST is set by the image's entrypoint to the host name the app is served at behind
// Dockside's proxy. Behind the proxy the page is HTTPS on port 443, so Vite's live-update socket
// connects there too, and only that host name is accepted. Without it, as with a plain
// `docker run`, any host name is accepted and the socket uses the dev server's own port.
const devtainerHost = process.env.DEVTAINER_HOST

// https://vite.dev/config/
export default defineConfig({
  plugins: [react()],
  server: {
    host: true,
    port: 5173,
    strictPort: true,
    allowedHosts: devtainerHost ? [devtainerHost] : true,
    hmr: devtainerHost ? { protocol: 'wss', clientPort: 443 } : true,
  },
})
