/**
 * lib/routes/platform.ts -- the vendor's four actions, as named in lib/tiers.ts.
 *
 *   Create a league       app.create_league
 *   Invite a league admin app.platform_invite_admin
 *   See every league      app.platform_leagues
 *   Suspend a league      app.suspend_league / app.unsuspend_league
 *
 * NOT ONE OF THESE HANDLERS CHECKS WHETHER THE CALLER IS A PLATFORM OWNER.
 * app.require_platform_owner() is the first line of every one of those
 * functions, and pd_anon holds no EXECUTE on any of them, so an anonymous
 * caller is refused by the privilege check before the function is even entered.
 * A second check here would be a second thing to get wrong, and the only way it
 * could ever differ from the database's answer is by being wrong.
 *
 * WHAT COMES BACK IS THE PRIVACY SPECIFICATION. app.platform_leagues() returns
 * league names, counts and dates -- player_count is an integer and there is no
 * function on this seat that returns a child's name, a jersey, a play slug or a
 * play document. This file adds nothing to that and takes nothing away: it
 * selects the function's own columns, casts the bigint counts to int so JSON
 * carries numbers rather than strings, and hands them on.
 */

import { asCaller, type Tx } from "../db";
import { json, optInt, optInterval, optObject, optStr, optUuid, pathUuid, readJson, route, str } from "../http";
import { ApiError } from "../errors";
import { callerFrom } from "../session";

type LeagueRow = {
  league_id: string;
  league_name: string;
  status: string;
  plan: string;
  seats_purchased: number | null;
  contract_ends_on: string | null;
  season_count: number;
  season_first_start: string | null;
  season_last_end: string | null;
  team_count: number;
  coach_seats: number;
  board_seats: number;
  player_count: number;
  play_count: number;
  last_play_edit: string | null;
  created_at: string;
};

const LEAGUES_SQL = `
  select league_id,
         league_name,
         status,
         plan,
         seats_purchased,
         contract_ends_on,
         season_count::int   as season_count,
         season_first_start,
         season_last_end,
         team_count::int     as team_count,
         coach_seats::int    as coach_seats,
         board_seats::int    as board_seats,
         player_count::int   as player_count,
         play_count::int     as play_count,
         last_play_edit,
         created_at
    from app.platform_leagues()
`;

/** GET /api/platform/leagues */
export const listLeagues = route(async (req) => {
  const rows = await asCaller(callerFrom(req), async (tx: Tx) => {
    const r = await tx.query<LeagueRow>(LEAGUES_SQL);
    return r.rows;
  });
  return json({ leagues: rows });
});

/** POST /api/platform/leagues -- a sale. */
export const createLeague = route(async (req) => {
  const body = await readJson(req);
  const name = str(body, "name");
  const ruleset = optObject(body, "ruleset");
  const plan = optStr(body, "plan");
  const seats = optInt(body, "seats");

  const id = await asCaller(callerFrom(req), async (tx) => {
    const r = await tx.query<{ league_id: string }>(
      `select app.create_league($1, coalesce($2::jsonb, '{}'::jsonb), coalesce($3, 'trial'), $4) as league_id`,
      [name, ruleset ? JSON.stringify(ruleset) : null, plan, seats],
    );
    return r.rows[0]?.league_id ?? null;
  });
  if (!id) throw new ApiError(500);
  return json({ league_id: id }, 201);
});

/**
 * POST /api/platform/leagues/[leagueId]/status  { status, reason? }
 *
 * Suspension refuses new seats and deletes nothing -- the function returns a
 * census of what it left alone, and that census is passed straight through
 * because it is the answer to "what did this do to my league".
 */
export const setLeagueStatus = route<{ leagueId: string }>(async (req, ctx) => {
  const leagueId = await pathUuid(ctx, "leagueId");
  const body = await readJson(req);
  const status = str(body, "status");
  if (status !== "suspended" && status !== "active") throw new ApiError(400);
  const reason = optStr(body, "reason");

  const result = await asCaller(callerFrom(req), async (tx) => {
    const r =
      status === "suspended"
        ? await tx.query<{ result: unknown }>(`select app.suspend_league($1, $2) as result`, [leagueId, reason])
        : await tx.query<{ result: unknown }>(`select app.unsuspend_league($1) as result`, [leagueId]);
    return r.rows[0]?.result ?? null;
  });
  return json({ result });
});

/**
 * POST /api/platform/invites  { league_id, email, valid_for? }
 *
 * The first admin seat of a brand new league. app.issue_invite() cannot do this
 * -- it wants an admin of the league to authorise it and a new league has none
 * -- which is the correction lib/tiers.ts records.
 *
 * The token comes back in plaintext exactly once, here, and is written to no
 * log: the invites table keeps only its sha256, auth_events records that an
 * invitation was issued and not what it was, and nothing in this repo prints
 * it. Whoever calls this endpoint is the thing that emails it.
 */
export const inviteLeagueAdmin = route(async (req) => {
  const body = await readJson(req);
  // Shape-checked here so a malformed id is a 400 whoever sends it, rather than
  // a cast error for the vendor and a 403 for everybody else.
  const leagueId = optUuid(body, "league_id");
  if (!leagueId) throw new ApiError(400);
  const email = str(body, "email");
  const validFor = optInterval(body, "valid_for");

  const row = await asCaller(callerFrom(req), async (tx) => {
    const r = await tx.query<{ invite_id: string; token: string }>(
      `select invite_id, token
         from app.platform_invite_admin($1::uuid, $2, coalesce($3::interval, interval '14 days'))`,
      [leagueId, email, validFor],
    );
    return r.rows[0] ?? null;
  });
  if (!row) throw new ApiError(500);
  return json({ invite_id: row.invite_id, token: row.token, shown_once: true }, 201);
});
