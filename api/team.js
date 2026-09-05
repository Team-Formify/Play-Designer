/* GET  /api/team?team=<uuid>          one team, everything the coach hub draws
 * POST /api/team?team=<uuid>&do=word  rotate the boys' word
 * POST /api/team?team=<uuid>&do=staff invite a coach   { email, role }
 * POST /api/team?team=<uuid>&do=player add a roster slot { jersey }
 *
 * One function rather than four files. Vercel bills and cold-starts per
 * function, and these are the four verbs of a single screen; splitting them
 * would mean four cold starts to draw one page on a practice field.
 *
 * The handlers are product/hub/lib/routes/coach.ts, compiled into api/_lib.
 * Nothing here decides who may do what -- see that file's header.
 */
const { handler } = require("./_lib/adapter.js");
const C = require("./_lib/routes/coach.js");

const POST = { word: C.rotateTeamWord, staff: C.inviteStaff, player: C.addPlayer };

module.exports = function (req, res) {
  const method = (req.method || "GET").toUpperCase();
  if (method === "GET") return handler(C.teamOverview, { methods: ["GET"] })(req, res);
  if (method === "POST") {
    let action = "";
    try { action = new URL(req.url, "http://x").searchParams.get("do") || ""; } catch {}
    const fn = POST[action];
    if (!fn) {
      res.statusCode = 400;
      res.setHeader("content-type", "application/json");
      return res.end(JSON.stringify({ error: "do must be one of: " + Object.keys(POST).join(", ") }));
    }
    return handler(fn, { methods: ["POST"] })(req, res);
  }
  res.setHeader("Allow", "GET, POST");
  res.statusCode = 405;
  res.setHeader("content-type", "application/json");
  res.end(JSON.stringify({ error: "GET or POST only" }));
};
