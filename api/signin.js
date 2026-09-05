/* PREVIEW SIGN-IN. Read this before using it for anything.
 *
 * THIS IS NOT THE PRODUCTION LOGIN AND MUST NOT BECOME IT.
 *
 * The database has known all four tiers since 0004_auth.sql and refuses across
 * them under 1,308 tests. What it has never had is an IDENTITY PROVIDER: there
 * is no users table, no password column, and no email round trip anywhere in
 * this schema. `auth.uid()` reads a GUC that something upstream is trusted to
 * have stamped honestly. In production that upstream is Supabase Auth putting a
 * verified JWT's claims in request.jwt.claims -- and it does not exist yet.
 *
 * So this door exists to let the founders SEE the real software: real rows,
 * real policies, real refusals, with identity asserted by a shared passphrase
 * rather than proved. It is impersonation with a lock on it.
 *
 * WHAT KEEPS IT FROM BEING A HOLE, TODAY:
 *   - It refuses entirely unless HUB_SIGNIN_SECRET is set. No secret, no door.
 *   - The passphrase is compared in constant time.
 *   - It will only sign you in AS AN ACCOUNT THE DATABASE ALREADY KNOWS: the
 *     uuid must already hold a membership, a league seat, or a platform seat.
 *     It cannot mint an identity out of nothing, so it cannot invent a coach
 *     for a team that never invited one.
 *   - The cookie is HttpOnly, Secure, SameSite=Lax and short-lived.
 *
 * WHAT IT STILL IS: anybody holding that one passphrase can be any existing
 * account. That is acceptable for two founders looking at their own data and is
 * not acceptable for a single real customer. Before anybody outside sees this,
 * either HUB_SIGNIN_SECRET comes off the deployment -- which turns this endpoint
 * off by itself -- or it is replaced by a real verifier.
 *
 * Needs: HUB_SIGNIN_SECRET, HUB_SESSION_SECRET, HUB_DATABASE_URL.
 */
const { timingSafeEqual } = require("node:crypto");
const { ensurePool, readRaw } = require("./_lib/adapter.js");
const { asCaller, asUser, ANON } = require("./_lib/db.js");
const { mintSession, sessionCookie, isUuid } = require("./_lib/session.js");

function sameSecret(a, b) {
  const x = Buffer.from(String(a || ""), "utf8");
  const y = Buffer.from(String(b || ""), "utf8");
  if (x.length !== y.length || x.length === 0) return false;
  return timingSafeEqual(x, y);
}

function send(res, status, body, headers) {
  res.statusCode = status;
  res.setHeader("content-type", "application/json; charset=utf-8");
  res.setHeader("cache-control", "no-store");
  if (headers && headers["set-cookie"]) res.setHeader("Set-Cookie", headers["set-cookie"]);
  res.end(JSON.stringify(body));
}

module.exports = async function handler(req, res) {
  if ((req.method || "GET").toUpperCase() !== "POST") {
    res.setHeader("Allow", "POST");
    return send(res, 405, { error: "POST only" });
  }

  const secret = process.env.HUB_SIGNIN_SECRET;
  if (!secret) {
    // Absent secret disables the door rather than defaulting it open.
    return send(res, 501, {
      error: "Preview sign-in is switched off on this deployment.",
      configured: false,
    });
  }
  if (!process.env.HUB_SESSION_SECRET || process.env.HUB_SESSION_SECRET.length < 16) {
    return send(res, 501, { error: "HUB_SESSION_SECRET is not set.", configured: false });
  }
  if (!ensurePool()) {
    return send(res, 501, { error: "HUB_DATABASE_URL is not set.", configured: false });
  }

  let body = {};
  try { body = JSON.parse((await readRaw(req)).toString("utf8") || "{}"); } catch { /* 400 below */ }

  if (!sameSecret(body.passphrase, secret)) {
    // One answer for a wrong passphrase and a missing one.
    return send(res, 401, { error: "No." });
  }
  const userId = String(body.user_id || "").trim();
  if (!isUuid(userId)) return send(res, 400, { error: "user_id must be a uuid." });
  const email = body.email ? String(body.email).trim().toLowerCase() : null;

  /* THE ACCOUNT MUST ALREADY EXIST. Asked as the OWNER-less anonymous caller
   * would see nothing, and as the user themselves it would be circular, so this
   * one query runs through a SECURITY DEFINER seat check plus two direct reads
   * that RLS cannot answer for an anonymous session -- which is why it is asked
   * as the user being requested and then verified to be non-empty. If that user
   * holds no seat anywhere, the lists are empty and we refuse. */
  let seats;
  try {
    seats = await asCaller(asUser(userId, email), async (tx) => {
      const m = await tx.query(
        `select count(*)::int as n from public.memberships where user_id = (select auth.uid())`,
      );
      const l = await tx.query(
        `select count(*)::int as n from public.league_memberships where user_id = (select auth.uid())`,
      );
      const p = await tx.query(`select app.is_platform_owner() as owner`);
      return {
        teams: m.rows[0] ? m.rows[0].n : 0,
        leagues: l.rows[0] ? l.rows[0].n : 0,
        platform: p.rows[0] ? p.rows[0].owner === true : false,
      };
    });
  } catch (e) {
    return send(res, 502, { error: String((e && e.message) || e).slice(0, 200) });
  }

  if (!seats.teams && !seats.leagues && !seats.platform) {
    return send(res, 403, {
      error: "That account holds no seat. Preview sign-in cannot create one — it can only stand in for somebody the database already knows.",
    });
  }

  const token = mintSession(userId, email, 60 * 60 * 8);
  return send(res, 200, {
    ok: true,
    user_id: userId,
    email,
    seats,
    preview: true,
  }, { "set-cookie": sessionCookie(token) });
};
