/**
 * THE THREE TIERS, and who may do what at each.
 *
 * This mirrors what the database already enforces — it does not invent a new
 * permission model. Every action named here maps to a function in
 * `product/db/migrations/0004_auth.sql` that has already been attacked in `test-auth.sql`, so
 * the screen is a face on a capability that refuses to misbehave on its own.
 *
 * PLATFORM now exists (`product/db/migrations/0005_platform.sql`, 252 tests). The seat holds no
 * row-level reach at all — a platform owner reading `plays` or `players`
 * directly gets ZERO rows, verified against a database where 6 plays and 31
 * children were sitting there. Everything it sees comes through SECURITY
 * DEFINER functions whose return types ARE the privacy specification: league
 * names, seats, contract dates, and player_count as an INTEGER. Zero of 31
 * surnames appear anywhere in what it can call.
 *
 * FOUR TIERS, NOT THREE. The player tier was missing from this file while
 * existing in the database the whole time -- public.player_words, created in
 * 0004_auth.sql, with app.player_team_id() re-checking the pair on EVERY
 * statement. It is listed here because a map of the permission model that
 * leaves out a quarter of it is worse than no map: it is a map somebody trusts.
 *
 * It is deliberately not an account, and that is the interesting part. A boy
 * has no login, no session and no ticket to expire -- the word IS the
 * credential, verified per statement, which is what makes rotation bite the
 * moment a coach presses it rather than whenever a token would have run out.
 * It is also why the boys' page is anonymous (pd_anon) and holds no EXECUTE on
 * anything that writes.
 *
 * One correction this file needed: "Invite a league admin" pointed at
 * `app.issue_invite`, which cannot do it — `app.may_staff_league()` is
 * admin-of-that-league, and a brand-new league has no admin to authorise
 * anything. The real function is `app.platform_invite_admin()`. A screen that
 * names the wrong function is the same lie as a button that does nothing.
 */
export type Tier = "platform" | "league" | "team" | "player";

export interface Action {
  label: string;
  detail: string;
  fn: string | null;
  needsSchema?: boolean;
  destructive?: boolean;
}

export const TIERS: Record<Tier, { name: string; who: string; blurb: string; actions: Action[] }> = {
  platform: {
    name: "Master hub",
    who: "us",
    blurb: "Every league on the platform. This is the only place that sees across tenants, which is why it is the smallest surface in the product.",
    actions: [
      { label: "Create a league", detail: "Name it, set its ruleset, open its first admin seat.", fn: "app.create_league" },
      { label: "Invite a league admin", detail: "One email, one league. They build out their own teams from there.", fn: "app.platform_invite_admin" },
      { label: "See every league", detail: "Names, team counts, seats used \u2014 and counts of children, never their names.", fn: "app.platform_leagues" },
      { label: "Suspend a league", detail: "Billing lapsed or the contract ended. Refuses new seats; deletes nothing, and the coach keeps editing his book.", fn: "app.suspend_league", destructive: true },
    ],
  },
  league: {
    name: "League hub",
    who: "the board",
    blurb: "One league. Its teams, its coaches, its rulebook, and the record of who changed what.",
    actions: [
      { label: "Add a team", detail: "A team in this league, for a season.", fn: "app.create_team", needsSchema: true },
      { label: "Invite a head coach", detail: "One email, one team, one role. Invite-only — nobody joins a team they were not sent to.", fn: "app.issue_invite" },
      { label: "Set the league rulebook", detail: "X-man weight, whether field goals are allowed, minimum plays. Data, not constants.", fn: "leagues.ruleset" },
      { label: "Read the audit log", detail: "Every grant, revocation and invite. Insert-only — it cannot be doctored.", fn: "auth_events" },
      { label: "Remove a child on request", detail: "A parent asks. The player goes; every play he was in keeps its shape and reads a jersey number.", fn: "app.tombstone_player", destructive: true },
    ],
  },
  team: {
    name: "Coach hub",
    who: "a head coach",
    blurb: "One team. His staff, his roster, his book — and the word the boys use to look at it.",
    actions: [
      { label: "Invite an assistant", detail: "Head coaches only. An assistant cannot staff the team he is on.", fn: "app.issue_invite" },
      { label: "Manage the roster", detail: "Last name and jersey. No photos, no weights — deliberately.", fn: "players" },
      { label: "Rotate the boys' word", detail: "Read-only, one team, no account. Rotating it cuts the old one off on the next request.", fn: "app.rotate_player_word" },
      { label: "Open the playbook", detail: "The designer, the formations, and the engine that runs them.", fn: "plays" },
    ],
  },
  player: {
    name: "Player hub",
    who: "a boy on the team",
    blurb: "One team's playbook, read only, with no account at all. The word his coach gives him IS the credential \u2014 there is no login to forget and no session to expire.",
    actions: [
      { label: "Watch the play run", detail: "Every man walks his own route on one clock, and stops where his block or his tackle happens.", fn: "learn.html" },
      { label: "Line me up", detail: "Where does this spot stand? Tap the field; it scores the tap in yards.", fn: "learn.html" },
      { label: "My job", detail: "Multiple choice from the written jobs \u2014 then who he is across from, what that man will try, and how he beats him.", fn: "learn.html" },
      { label: "Nothing else", detail: "No roster he can edit, no other team he can see, and no way to write anything. pd_anon holds no EXECUTE on any staff function.", fn: "app.player_team_id" },
    ],
  },
};
