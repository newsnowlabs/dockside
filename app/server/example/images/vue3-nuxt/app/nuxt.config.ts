// DEVTAINER_HOST is set by the image's entrypoint to the host name the app is served at behind
// Dockside's proxy, and only that host name is accepted. Without it, as with a plain `docker run`,
// any host name is accepted.
const devtainerHost = process.env.DEVTAINER_HOST

// https://nuxt.com/docs/api/configuration/nuxt-config
export default defineNuxtConfig({
  compatibilityDate: '2025-07-15',
  devtools: { enabled: false },
  telemetry: false,
  devServer: { host: '0.0.0.0', port: 3000 },
  vite: {
    server: {
      allowedHosts: devtainerHost ? [devtainerHost] : true,
    },
  },
})
