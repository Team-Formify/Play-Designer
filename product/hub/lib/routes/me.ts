/**
 * lib/routes/me.ts -- what this session is, answered by the database.
 *
 * The one screen every hub needs before it can draw anything: who am I, and
 * which seats do I hold. It is also the cheapest possible demonstration that
 * the isolation is real, because NOTHING HERE FILTERS BY TENANT. The queries
 * say `select ... from public.teams` with no where clause; the rows that come
 * back are the caller's because 0003_rls.sql says so, not because this file
 * remembered to ask.
 *
 * If a coach in another league ever appears in this response, the bug is in the
 * database and 183 isolation tests were wrong -- there is no application-side
 * filter here to have got wrong instead. That is the whole design.
 *
 * A session with no identity is not an error. It answers `signed_in: false`
 * with empty lists, because the boys' page and a signed-out visitor both hit
 * this and neither is a failure.
 */

import { asCaller } from "../db";
import { json, route } from "../http";
import { callerFrom } from "../session";

type TeamRow = {
  id: string;
  name: string;
  grade: string;
  season: string | null;
  league: string | null;
  league_id: string;
  role: string;
};
type LeagueRow = { id: string; name: string; kind: string; role: string };

/** GET /api/me */
export const me = route(async (req) => {
  const caller = callerFrom(req);

  const out = await asCaller(caller, async (tx) => {
    const who = await tx.query<{ uid: string | null; email: string | null; role: string }>(
      `select auth.uid()::text as uid, auth.email() as email, current_user as role`,
    );

    // No tenant filter, on purpose. See the header.
    // The season and the league are joined in because without them a coach who
    // holds the same team in two seasons -- which Dom does -- sees two rows
    // reading "Lehi / 8 / assistant" and cannot tell them apart. Both joins are
    // LEFT: a row the caller cannot see comes back null rather than dropping
    // the team out of his own list.
    const teams = await tx.query<TeamRow>(
      `select t.id, t.name, t.grade, s.name as season, l.name as league,
              t.league_id, m.role
         from public.teams t
         join public.memberships m
           on m.team_id = t.id and m.user_id = (select auth.uid())
         left join public.seasons s on s.id = t.season_id
         left join public.leagues l on l.id = t.league_id
        order by s.starts_on desc nulls last, t.name, t.grade`,
    );

    const leagues = await tx.query<LeagueRow>(
      `select l.id, l.name, l.kind, lm.role
         from public.leagues l
         join public.league_memberships lm
           on lm.league_id = l.id and lm.user_id = (select auth.uid())
        order by l.name`,
    );

    // A boolean, never the list. What the platform seat can SEE is
    // 0005_platform.sql's business and is not widened by asking here.
    const platform = await tx.query<{ owner: boolean }>(
      `select app.is_platform_owner() as owner`,
    );

    return {
      signed_in: who.rows[0]?.uid !== null,
      user_id: who.rows[0]?.uid ?? null,
      email: who.rows[0]?.email ?? null,
      db_role: who.rows[0]?.role ?? null,
      is_platform_owner: platform.rows[0]?.owner === true,
      teams: teams.rows,
      leagues: leagues.rows,
    };
  });

  return json(out);
});
