import adapter from '@sveltejs/adapter-auto';
import { sveltekit } from '@sveltejs/kit/vite';
import { defineConfig } from 'vite';

// DEVTAINER_HOST is set by the image's entrypoint to the host name the app is served at behind
// Dockside's proxy. Behind the proxy the page is HTTPS on port 443, so Vite's live-update socket
// connects there too, and only that host name is accepted. Without it, as with a plain
// `docker run`, any host name is accepted and the socket uses the dev server's own port.
const devtainerHost = process.env.DEVTAINER_HOST;

export default defineConfig({
	server: {
		host: true,
		port: 5173,
		strictPort: true,
		allowedHosts: devtainerHost ? [devtainerHost] : true,
		hmr: devtainerHost ? { protocol: 'wss', clientPort: 443 } : true
	},
	plugins: [
		sveltekit({
			compilerOptions: {
				// Force runes mode for the project, except for libraries. Can be removed in svelte 6.
				runes: ({ filename }) =>
					filename.split(/[/\\]/).includes('node_modules') ? undefined : true
			},

			// adapter-auto only supports some environments, see https://svelte.dev/docs/kit/adapter-auto for a list.
			// If your environment is not supported, or you settled on a specific environment, switch out the adapter.
			// See https://svelte.dev/docs/kit/adapters for more information about adapters.
			adapter: adapter()
		})
	]
});
