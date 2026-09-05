/* GET /api/me -- who this session is, answered by the database.
 *
 * A thin wrapper: the handler is product/hub/lib/routes/me.ts, compiled into
 * api/_lib by scripts/sync-api-lib.mjs. Nothing here filters by tenant, and
 * that is the point -- see that file's header.
 */
const { handler } = require("./_lib/adapter.js");
const { me } = require("./_lib/routes/me.js");
module.exports = handler(me, { methods: ["GET"] });
