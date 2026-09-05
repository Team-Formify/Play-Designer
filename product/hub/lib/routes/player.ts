/**
 * lib/routes/player.ts -- the boys, who have no accounts.
 *
 * GET /api/player/book
 *   headers: x-player-team: <uuid>
 *            x-player-word: <the word the coach read out>
 *
 * THE TEAM IS NOT A PARAMETER OF THIS REQUEST IN THE SENSE THAT MATTERS. It is
 * half of one credential -- the link carries the team, the word is the secret,
 * and app.player_team_id() verifies the PAIR against player_words on every
 * statement. Naming a team you do not hold the word for resolves to NULL, and
 * `team_id = NULL` is never true in either of the two policies the word
 * unlocks. There is no route in this API that takes a team from the boys and
 * trusts it.
 *
 * IT REACHES EXACTLY TWO TABLES, because 0004_auth.sql grants it exactly two
 * policies: this team's plays and this team's players. Not the team row, not
 * the league, not consents, not tombstones, not memberships, and not another
 * team's anything. This handler does not enforce that -- it could not, and does
 * not try; it asks for the two things the word is for and the database answers.
 *
 * READ ONLY. pd_anon holds no write privilege on any table in the schema, so
 * the boys' credential cannot change a play even by accident. Same promise
 * learn.html makes on the field client: a link that cannot edit anything.
 */

import { asCaller } from "../db";
import { ApiError } from "../errors";
import { json, route } from "../http";
import { callerFrom } from "../session";

type PlayerRow = { id: string; last: string; first: string | null; jersey: string | null };
type PlayRow = { id: string; slug: string; doc: unknown; updated_at: string };

export const readBook = route(async (req) => {
  const out = await asCaller(callerFrom(req), async (tx) => {
    // The database resolves the credential to a team, or to NULL. This is the
    // same function the two policies call; asking it here is how the handler
    // learns whether there is anything to look for, not a second opinion about
    // whether the caller may look.
    const who = await tx.query<{ team_id: string | null }>(`select app.player_team_id() as team_id`);
    const teamId = who.rows[0]?.team_id ?? null;
    if (!teamId) throw new ApiError(404);

    const players = await tx.query<PlayerRow>(
      `select id, last, first, jersey from public.players where team_id = $1 order by last, coalesce(jersey, '')`,
      [teamId],
    );
    const plays = await tx.query<PlayRow>(
      `select id, slug, doc, updated_at from public.plays where team_id = $1 order by slug`,
      [teamId],
    );
    return { team_id: teamId, players: players.rows, plays: plays.rows };
  });
  return json(out);
});
