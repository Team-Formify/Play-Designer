/**
 * lib/session.ts -- where identity comes from, and the only place it comes from.
 *
 * IDENTITY COMES FROM THE SESSION, NEVER FROM THE REQUEST BODY. A `team_id` in
 * a payload is a hint about what to fetch; it is never proof of who is asking.
 * Every handler in lib/routes builds its Caller here and nowhere else, so there
 * is no path by which a field in a JSON body becomes an identity claim.
 *
 * The token is an HMAC-SHA256 over a compact JSON payload -- a stand-in with
 * exactly the shape of the thing it stands in for. In production the claims
 * arrive in a Supabase JWT and PostgREST puts them in request.jwt.claims; here
 * they arrive in a cookie this file signed. Either way the API's job is the
 * same: verify, then hand `sub` and `email` to the database as app.user_id and
 * app.user_email. 0002_schema.sql and 0004_auth.sql already say those two GUCs map 1:1 to
 * auth.uid() and auth.email(), so swapping this file for a JWT verifier changes
 * nothing above it.
 *
 * FAIL CLOSED. A missing secret, a missing token, a bad signature, an expired
 * payload, a `sub` that is not a uuid: all of them produce the anonymous
 * caller, not an error and not a partial identity. The database is then asked
 * the question anyway, and answers with nothing -- which is the point. An
 * unauthenticated request is refused by RLS and by the missing EXECUTE grants
 * on pd_anon, not by an `if` in a handler.
 *
 * THE BOYS' WORD is not a session and deliberately does not get one. It arrives
 * as two headers, is never stored, and is re-verified against player_words on
 * every single statement by app.player_team_id(). That is what makes rotation
 * bite immediately: there is no ticket to expire.
 */

import { createHmac, timingSafeEqual } from "node:crypto";
import { ANON, asPlayer, asUser, type Caller } from "./db";
import { ApiError } from "./errors";

export const SESSION_COOKIE = "hub_session";
const DEFAULT_TTL_SECONDS = 60 * 60 * 12;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export interface SessionClaims {
  /** The account id. Becomes app.user_id, which is auth.uid(). */
  sub: string;
  /** The verified address. Becomes app.user_email, which is auth.email(). */
  email: string | null;
  /** Seconds since the epoch. */
  exp: number;
}

export function isUuid(v: unknown): v is string {
  return typeof v === "string" && UUID_RE.test(v);
}

function secret(): Buffer | null {
  const s = process.env.HUB_SESSION_SECRET;
  if (!s || s.length < 16) return null;
  return Buffer.from(s, "utf8");
}

const b64u = (b: Buffer): string => b.toString("base64url");

function sign(payload: string, key: Buffer): string {
  return b64u(createHmac("sha256", key).update(payload).digest());
}

/**
 * Mint a session. Called by POST /api/session, which is itself gated: without
 * an identity provider wired up there is no credential to check, so that route
 * refuses to run outside development. See lib/routes/session.ts.
 */
export function mintSession(sub: string, email: string | null, ttlSeconds = DEFAULT_TTL_SECONDS): string {
  const key = secret();
  if (!key) throw new ApiError(501);
  if (!isUuid(sub)) throw new ApiError(400);
  const claims: SessionClaims = {
    sub,
    email: email ? email.trim().toLowerCase() : null,
    exp: Math.floor(Date.now() / 1000) + ttlSeconds,
  };
  const body = b64u(Buffer.from(JSON.stringify(claims), "utf8"));
  return `${body}.${sign(body, key)}`;
}

/** Verify a token. Any doubt at all returns null, which means "anonymous". */
export function verifySession(token: string | null | undefined): SessionClaims | null {
  const key = secret();
  if (!key || !token) return null;
  const dot = token.indexOf(".");
  if (dot <= 0 || dot === token.length - 1) return null;
  const body = token.slice(0, dot);
  const mac = token.slice(dot + 1);

  const expected = Buffer.from(sign(body, key), "utf8");
  const given = Buffer.from(mac, "utf8");
  if (expected.length !== given.length) return null;
  if (!timingSafeEqual(expected, given)) return null;

  try {
    const claims = JSON.parse(Buffer.from(body, "base64url").toString("utf8")) as unknown;
    if (typeof claims !== "object" || claims === null) return null;
    const c = claims as Partial<SessionClaims>;
    if (!isUuid(c.sub)) return null;
    if (typeof c.exp !== "number" || c.exp * 1000 <= Date.now()) return null;
    const email = typeof c.email === "string" && c.email.includes("@") ? c.email.toLowerCase() : null;
    return { sub: c.sub, email, exp: c.exp };
  } catch {
    return null;
  }
}

function cookieValue(header: string | null, name: string): string | null {
  if (!header) return null;
  for (const part of header.split(";")) {
    const eq = part.indexOf("=");
    if (eq < 0) continue;
    if (part.slice(0, eq).trim() !== name) continue;
    return decodeURIComponent(part.slice(eq + 1).trim());
  }
  return null;
}

/**
 * The one function that decides who is asking. Reads a cookie, a bearer header
 * and the two boys'-word headers -- and nothing else. It never touches the body.
 */
export function callerFrom(req: Request): Caller {
  const team = req.headers.get("x-player-team");
  const word = req.headers.get("x-player-word");
  if (isUuid(team) && word && word.trim() !== "") {
    // The word is a read credential for one team and is not combined with an
    // account: presenting it asks the database "what may this word see".
    return asPlayer(team, word.trim());
  }

  const auth = req.headers.get("authorization");
  const bearer = auth && /^bearer /i.test(auth) ? auth.slice(7).trim() : null;
  const claims = verifySession(bearer ?? cookieValue(req.headers.get("cookie"), SESSION_COOKIE));
  return claims ? asUser(claims.sub, claims.email) : ANON;
}

export function sessionCookie(token: string, maxAgeSeconds = DEFAULT_TTL_SECONDS): string {
  return [
    `${SESSION_COOKIE}=${encodeURIComponent(token)}`,
    "Path=/",
    "HttpOnly",
    "SameSite=Lax",
    "Secure",
    `Max-Age=${maxAgeSeconds}`,
  ].join("; ");
}

export function clearedSessionCookie(): string {
  return `${SESSION_COOKIE}=; Path=/; HttpOnly; SameSite=Lax; Secure; Max-Age=0`;
}
