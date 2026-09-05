/**
 * lib/routes/invites.ts -- the only way into a team or a league.
 *
 *   Invite a head coach / an assistant   app.issue_invite
 *   Redeem an invitation                 app.accept_invite
 *
 * `team_id` IS IN THE BODY OF POST /api/invites, AND IT IS NOT IDENTITY. It
 * names the team the invitation is FOR. Who is asking comes from the session
 * and nowhere else, and app.may_staff_team() decides -- head of that team, or
 * admin of its league. Posting somebody else's team id gets a 403 whether that
 * team exists or not. The test suite sends a foreign team id from a coach's
 * session and shows that it changes nothing.
 *
 * ACCEPTANCE TAKES THE TOKEN AND NOTHING ELSE. That is auth.sql's design and it
 * is why this handler is four lines: there is no team parameter to tamper with,
 * because the team is a property of the row the token hashes to, and no tenant
 * holds a write privilege on that row.
 *
 * ONE REFUSAL FOR EVERY WAY OF FAILING. app.accept_invite() distinguishes
 * "no such token" (22023) from "addressed to somebody else" (42501), which is
 * the right thing for a database to do and the wrong thing to put on the wire:
 * the pair is an oracle that says whether a token you found is real. Both
 * become the same 400 with the same body, so a forwarded link and a guessed one
 * are indistinguishable from outside.
 */

import { asCaller } from "../db";
import { ApiError } from "../errors";
import { json, optInterval, optUuid, readJson, route, str } from "../http";
import { callerFrom } from "../session";

/** POST /api/invites  { email, role, team_id? | league_id?, valid_for? } */
export const issueInvite = route(async (req) => {
  const body = await readJson(req);
  const email = str(body, "email");
  const role = str(body, "role");
  const teamId = optUuid(body, "team_id");
  const leagueId = optUuid(body, "league_id");
  const validFor = optInterval(body, "valid_for");
  // Exactly one scope. The database says so too (invites_one_scope, and a raise
  // in the function); this only saves a round trip.
  if ((teamId === null) === (leagueId === null)) throw new ApiError(400);

  const row = await asCaller(callerFrom(req), async (tx) => {
    const r = await tx.query<{ invite_id: string; token: string }>(
      `select invite_id, token
         from app.issue_invite($1, $2, $3::uuid, $4::uuid, coalesce($5::interval, interval '14 days'))`,
      [email, role, teamId, leagueId, validFor],
    );
    return r.rows[0] ?? null;
  });
  if (!row) throw new ApiError(500);
  return json({ invite_id: row.invite_id, token: row.token, shown_once: true }, 201);
});

const INVITE_REFUSED = "invitation is not valid";

/** POST /api/invites/accept  { token } */
export const acceptInvite = route(async (req) => {
  const body = await readJson(req);
  const token = str(body, "token");
  if (token.length > 200) throw new ApiError(400, INVITE_REFUSED);

  try {
    const result = await asCaller(callerFrom(req), async (tx) => {
      const r = await tx.query<{ result: unknown }>(`select app.accept_invite($1) as result`, [token]);
      return r.rows[0]?.result ?? null;
    });
    return json({ result });
  } catch (err) {
    // Every refusal the database can produce here collapses to one answer:
    // expired, withdrawn, already used, addressed to somebody else, not signed
    // in, or never existed. The caller learns only that it did not work.
    const code = (err as { code?: string }).code;
    if (code === "42501" || code === "22023") throw new ApiError(400, INVITE_REFUSED);
    throw err;
  }
});
