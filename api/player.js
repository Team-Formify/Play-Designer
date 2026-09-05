/* DELETE /api/player?team=<uuid>&player=<uuid>&reason=parent_request
 *
 * A parent asks for a child to be removed. The row goes; every play he was in
 * keeps its geometry and reads a jersey number. That is the BEFORE DELETE
 * trigger, not this endpoint. See product/hub/lib/routes/teams.ts.
 */
const { handler } = require("./_lib/adapter.js");
const { deletePlayer } = require("./_lib/routes/teams.js");
module.exports = handler(deletePlayer, {
  methods: ["DELETE", "POST"],
  params: (url) => ({
    teamId: url.searchParams.get("team") || "",
    playerId: url.searchParams.get("player") || "",
  }),
});
