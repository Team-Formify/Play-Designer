/**
 * lib/routes/teams.ts -- one team: its roster, its book, its boys' word, and
 * the one deletion that is allowed to remove a person.
 *
 *   Manage the roster        players            (read here)
 *   Open the playbook        plays              (read here)
 *   Rotate the boys' word    app.rotate_player_word
 *   Remove a child           app.tombstone_player (the trigger; the action is a
 *                                                  DELETE on players)
 *
 * THE TEAM ID IN THE PATH IS A FILTER, NOT A CLAIM. Every statement below
 * carries it as `where team_id = $1`, and every one of those tables is under
 * RLS: `plays_select_team` and `players_select` resolve the caller's own
 * memberships live. So the id narrows what comes back and the database decides
 * whether any of it may. Sending another coach's team id returns the same
 * nothing as sending a uuid that names no team at all.
 *
 * WHY THE 404 IS THE TEAMS ROW. The first statement of the two read handlers
 * asks for the team by id. If RLS hands back no row then, as far as this caller
 * is concerned, there is no such team -- whether it exists or not -- and both
 * cases answer `404 {"error":"not found"}`, byte for byte. There is no
 * membership check anywhere in this file; the absence of a row IS the answer.
 *
 * ONE ASYMMETRY, STATED RATHER THAN HIDDEN. A league board member can see the
 * teams row (teams_select covers their league) but rls.sql deliberately keeps
 * them out of plays -- a play is the coach's IP. So a board member reading
 * /plays gets 200 with an empty list rather than a refusal. That is RLS's
 * answer, unedited: they may know the team exists and may not know its book.
 * Restating it here as a 403 would mean this file re-deriving a policy, which
 * is the thing this API does not do.
 */

import { asCaller, type Tx } from "../db";
import { ApiError } from "../errors";
import { json, optInterval, optStr, pathUuid, readJson, route } from "../http";
import { callerFrom } from "../session";

type TeamRow = { id: string; name: string; grade: string; league_id: string; season_id: string };
type PlayerRow = { id: string; last: string; first: string | null; jersey: string | null };
type PlayRow = { id: string; slug: string; doc: unknown; updated_at: string };

async function teamOr404(tx: Tx, teamId: string): Promise<TeamRow> {
  const r = await tx.query<TeamRow>(
    `select id, name, grade, league_id, season_id from public.teams where id = $1`,
    [teamId],
  );
  const row = r.rows[0];
  if (!row) throw new ApiError(404);
  return row;
}

/** GET /api/teams/[teamId]/players */
export const readRoster = route<{ teamId: string }>(async (req, ctx) => {
  const teamId = await pathUuid(ctx, "teamId");
  const out = await asCaller(callerFrom(req), async (tx) => {
    const team = await teamOr404(tx, teamId);
    const r = await tx.query<PlayerRow>(
      `select id, last, first, jersey
         from public.players
        where team_id = $1
        order by last, coalesce(jersey, '')`,
      [teamId],
    );
    return { team, players: r.rows };
  });
  return json(out);
});

/** GET /api/teams/[teamId]/plays */
export const readPlays = route<{ teamId: string }>(async (req, ctx) => {
  const teamId = await pathUuid(ctx, "teamId");
  const out = await asCaller(callerFrom(req), async (tx) => {
    const team = await teamOr404(tx, teamId);
    const r = await tx.query<PlayRow>(
      `select id, slug, doc, updated_at
         from public.plays
        where team_id = $1
        order by slug`,
      [teamId],
    );
    return { team, plays: r.rows };
  });
  return json(out);
});

/**
 * POST /api/teams/[teamId]/word   { word?, valid_for? }
 *
 * Returns the word in plaintext once, for the coach to read out to the huddle.
 * Only its sha256 is stored, the audit log records that it changed and not what
 * to, and the old word stops working on the next statement -- there is no
 * session to expire.
 */
export const rotateWord = route<{ teamId: string }>(async (req, ctx) => {
  const teamId = await pathUuid(ctx, "teamId");
  const body = await readJson(req);
  const word = optStr(body, "word");
  const validFor = optInterval(body, "valid_for");

  const out = await asCaller(callerFrom(req), async (tx) => {
    const r = await tx.query<{ word: string }>(
      `select app.rotate_player_word($1, $2, $3::interval) as word`,
      [teamId, word, validFor],
    );
    return r.rows[0]?.word ?? null;
  });
  if (!out) throw new ApiError(500);
  return json({ team_id: teamId, word: out, shown_once: true });
});

/**
 * DELETE /api/teams/[teamId]/players/[playerId]?reason=parent_request
 *
 * A parent asks for a child to be removed. The player row goes; every play he
 * was in keeps its geometry and reads a jersey number. That is the BEFORE
 * DELETE trigger app.tombstone_player(), not this handler: all this does is
 * bind the reason for the same transaction and issue the DELETE.
 *
 * The reason is transaction-local for the same reason identity is. It is a fact
 * about ONE deletion; left session-level on a pooled connection it would end up
 * stamped on somebody else's.
 *
 * What comes back is the tombstone: a jersey, a count of plays redacted, and no
 * name -- the table has no name column, deliberately.
 */
export const deletePlayer = route<{ teamId: string; playerId: string }>(async (req, ctx) => {
  const teamId = await pathUuid(ctx, "teamId");
  const playerId = await pathUuid(ctx, "playerId");
  const url = new URL(req.url);
  const body = await readJson(req);
  const reason = url.searchParams.get("reason") ?? optStr(body, "reason") ?? "";

  const out = await asCaller(callerFrom(req), async (tx) => {
    await tx.query(`select set_config('app.deletion_reason', $1, true)`, [reason]);
    const gone = await tx.query<{ id: string }>(
      `delete from public.players where id = $1 and team_id = $2 returning id`,
      [playerId, teamId],
    );
    if (gone.rowCount !== 1) throw new ApiError(404);
    const stone = await tx.query<{ jersey: string | null; reason: string; plays_redacted: number }>(
      `select jersey, reason, plays_redacted
         from public.player_tombstones where player_id = $1`,
      [playerId],
    );
    return { tombstone: stone.rows[0] ?? null };
  });
  return json(out);
});
