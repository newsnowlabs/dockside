import type { NextConfig } from "next";

// DEVTAINER_HOST is set by the image's entrypoint to the host name the app is served at behind
// Dockside's proxy. The dev server answers requests for its assets only from the origins it is
// told of, and a page served at a host name other than localhost is such an origin.
const devtainerHost = process.env.DEVTAINER_HOST;

const nextConfig: NextConfig = {
  allowedDevOrigins: devtainerHost ? [devtainerHost] : [],
  cacheComponents: true,
  partialPrefetching: true,
  turbopack: {
    rules: {
      "*.css": {
        loaders: ["@tailwindcss/turbopack"],
        as: "*.css",
      },
    },
  },
};

export default nextConfig;
