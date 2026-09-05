/* GET /api/roster?team=<uuid> -- one team's roster.
 *
 * The handler is product/hub/lib/routes/teams.ts, which expects the team id as
 * a PATH parameter because it was written for Next's file routing. These
 * functions live at flat paths, so the adapter hands it the query string
 * instead. It is the same value reaching the same handler; RLS decides whether
 * any row comes back, and naming a team you do not coach returns nothing.
 */
const { handler } = require("./_lib/adapter.js");
const { readRoster } = require("./_lib/routes/teams.js");
module.exports = handler(readRoster, {
  methods: ["GET"],
  params: (url) => ({ teamId: url.searchParams.get("team") || "" }),
});
