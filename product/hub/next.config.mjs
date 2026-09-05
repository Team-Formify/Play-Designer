/**
 * Static export.
 *
 * The Vercel project serving this repo is a STATIC site — index.html and
 * friends, no Node runtime. The hub is a Next app, so it could not deploy
 * alongside and was screenshots-only. It has no API and no server data yet
 * (every tier is read from lib/tiers.ts), so exporting it to plain files costs
 * nothing today and makes it reachable.
 *
 * basePath because it is served from /hub, and unoptimized images
 * because the optimizer needs a server this project does not have.
 *
 * When the API layer lands this has to be revisited: an exported app cannot run
 * route handlers, and the hub will need its own Vercel project at that point.
 */
const nextConfig = {
  output: "export",
  basePath: "/hub",
  trailingSlash: true,
  images: { unoptimized: true },
};
export default nextConfig;
