/**
 * The routes baked to HTML at build time.
 *
 * List every route whose content is the same for all visitors between
 * deploys; leave out anything that shows live or per-visitor data — a
 * build-time snapshot of those would open stale. Adding a route here is the
 * whole job: tools/prerender.mjs writes it to dist/<route>/index.html and
 * the server maps the URL to that file.
 */
export const prerenderedRoutes: string[] = ["/"];
