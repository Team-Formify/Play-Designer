/* GET /api/plays?team=<uuid> -- one team's playbook. Same shape as roster.js. */
const { handler } = require("./_lib/adapter.js");
const { readPlays } = require("./_lib/routes/teams.js");
module.exports = handler(readPlays, {
  methods: ["GET"],
  params: (url) => ({ teamId: url.searchParams.get("team") || "" }),
});
