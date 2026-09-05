/**
 * lib/db.ts -- the one place a request reaches Postgres.
 *
 * THE RULE THIS FILE EXISTS TO ENFORCE: every statement runs AS THE CALLER,
 * through RLS. There is no service-role key here, no BYPASSRLS connection and
 * no `where team_id = $1 and user_is_allowed(...)` anywhere above it. The 21
 * policies in product/db/migrations/0003_rls.sql and the 43 security definer functions in
 * 0004_auth.sql / 0005_platform.sql ARE the authorization. This file's whole job is to
 * carry identity to them and get out of the way.
 *
 * The other product in this org got that backwards -- permissive policies, a
 * published key, and the tenant filter written by hand in every endpoint -- and
 * ended up with no isolation at all. See product/REUSE.md.
 *
 * HOW IDENTITY IS CARRIED, AND WHY IT IS TRANSACTION-LOCAL
 *
 *   set_config('app.user_id', $1, true)
 *                                 ^^^^ is_local = true
 *
 * `true` means the setting dies with the transaction. That is not a style
 * choice. A pool hands the same physical connection to the next request; a
 * session-level GUC (is_local = false) would still be sitting on it, and the
 * next caller -- possibly anonymous, possibly a coach in another league --
 * would execute under the previous caller's identity. Every policy in 0003_rls.sql
 * resolves `auth.uid()` live, so that is a complete tenancy bypass with no
 * code change anywhere. product/hub/test/api.test.mjs interleaves two requests
 * over one connection, and -- the part that actually catches it -- inspects a
 * RAW client from the same pool after a request finishes. That second probe is
 * the load-bearing one: a check made from inside a later asCaller() cannot see
 * the leak, because asCaller() rebinds all four GUCs on entry and overwrites
 * the stale value before anything reads it. Flipping this `true` to `false`
 * leaves such a suite entirely green.
 *
 * All four GUCs are bound on every transaction, to '' when absent, so a stale
 * value cannot survive even if some future edit dropped the tx-local flag by
 * accident. The database reads '' as NULL (`nullif(current_setting(...), '')`)
 * and every policy is false for NULL.
 *
 * THE ROLE. The connection logs in as pd_app, an ordinary role that is a
 * NOINHERIT member of pd_anon and pd_authenticated and holds nothing itself.
 * It is created by product/db/migrations/0008_app_role.sql -- which was written
 * because this paragraph described it for a while before any migration made it,
 * so the desk client could not be run against a database built from these files
 * at all. NOINHERIT is the load-bearing word: an INHERIT member would carry the
 * union of both roles' privileges on every connection, without SET ROLE, and
 * the paragraph below would be false. Each transaction does `set local role` down into exactly one
 * of them: pd_authenticated for a signed-in account, pd_anon for everybody
 * else, including a boys'-word session -- the boys' page is anonymous, which is
 * the whole point of the word. The privilege half of the design does real work
 * here: pd_anon holds no EXECUTE on app.issue_invite(), app.platform_leagues()
 * and the rest, so an anonymous caller is refused by the database before any
 * check inside those functions runs.
 *
 * ON SUPABASE this becomes the `authenticated` role and `request.jwt.claims`,
 * set by PostgREST from a verified JWT, and nothing above this file changes.
 */

// Default import, not a named one: `pg` is CommonJS and builds its exports at
// runtime, so Node's ESM named-export detection does not see `Pool`. Types come
// in separately, where the shape is known statically.
import pg from "pg";
import type { Pool as PgPool, PoolClient, QueryResult, QueryResultRow } from "pg";

const { Pool } = pg;

/**
 * The four claims the database understands, and nothing else. Deliberately a
 * flat record rather than a union: it is the exact shape of the four GUCs, so
 * there is no translation step where a claim could be dropped or invented.
 *
 * userId/email come from a verified session. playerTeam/playerWord come from
 * the boys' link and are verified per statement by app.player_team_id() --
 * naming the team is not a claim to it, the word is the secret and the database
 * checks the pair.
 */
export interface Caller {
  readonly userId: string | null;
  readonly email: string | null;
  readonly playerTeam: string | null;
  readonly playerWord: string | null;
}

export const ANON: Caller = { userId: null, email: null, playerTeam: null, playerWord: null };

export function asUser(userId: string, email: string | null): Caller {
  return { userId, email, playerTeam: null, playerWord: null };
}

export function asPlayer(teamId: string, word: string): Caller {
  return { userId: null, email: null, playerTeam: teamId, playerWord: word };
}

/** A signed-in caller gets the signed-in role. Everybody else gets pd_anon. */
function roleFor(who: Caller): "pd_authenticated" | "pd_anon" {
  return who.userId ? "pd_authenticated" : "pd_anon";
}

/**
 * The only handle a handler gets. No client, no pool, no `begin`: a handler
 * cannot open a second transaction, cannot change role, and cannot run a
 * statement outside the identity binding.
 */
export interface Tx {
  query<R extends QueryResultRow = QueryResultRow>(
    text: string,
    params?: readonly unknown[],
  ): Promise<QueryResult<R>>;
}

const BIND_IDENTITY = `
  select set_config('app.user_id',     $1, true),
         set_config('app.user_email',  $2, true),
         set_config('app.player_team', $3, true),
         set_config('app.player_word', $4, true)
`;

/** A request that hangs is a connection the next request cannot have. */
const STATEMENT_TIMEOUT_MS = 10_000;

let poolRef: PgPool | null = null;
let poolOpts: { connectionString?: string; max?: number } = {};

/**
 * Test seam. Also the only place the connection string is read, so there is
 * one answer to "which database is this talking to".
 */
export function configurePool(opts: { connectionString?: string; max?: number }): void {
  if (poolRef) throw new Error("configurePool: a pool is already open; call closePool() first");
  poolOpts = { ...opts };
}

export function pool(): PgPool {
  if (!poolRef) {
    const connectionString =
      poolOpts.connectionString ?? process.env.HUB_DATABASE_URL ?? process.env.DATABASE_URL;
    if (!connectionString) {
      throw new Error("HUB_DATABASE_URL is not set: the hub has no database to run as the caller against");
    }
    poolRef = new Pool({
      connectionString,
      max: poolOpts.max ?? 10,
      idleTimeoutMillis: 30_000,
      // A connection that dies mid-transaction must not take the process down.
      allowExitOnIdle: true,
    });
    poolRef.on("error", (err: Error) => {
      console.error("[db] idle client error:", err.message);
    });
  }
  return poolRef;
}

export async function closePool(): Promise<void> {
  const p = poolRef;
  poolRef = null;
  if (p) await p.end();
}

/**
 * Open a transaction, bind the caller's identity to it, run, commit.
 *
 * Ordering matters and is the reason this is one function rather than a
 * convention: BEGIN, then the role, then the identity, then the caller's
 * statements. Nothing the handler passes in can reach the database before the
 * identity is bound, so there is no window in which a query runs unattributed.
 *
 * On any throw the transaction rolls back before the connection goes back to
 * the pool; if even the rollback fails the connection is destroyed rather than
 * reused, because a connection whose transaction state is unknown is a
 * connection whose GUCs are unknown.
 */
export async function asCaller<T>(who: Caller, run: (tx: Tx) => Promise<T>): Promise<T> {
  const client: PoolClient = await pool().connect();
  let inTx = false;
  let poisoned = false;
  try {
    await client.query("begin");
    inTx = true;
    // Not parameterisable, so it is never interpolated from input: roleFor()
    // returns one of two compile-time constants.
    await client.query(`set local role ${roleFor(who)}`);
    await client.query(`set local statement_timeout = ${STATEMENT_TIMEOUT_MS}`);
    await client.query(BIND_IDENTITY, [
      who.userId ?? "",
      who.email ?? "",
      who.playerTeam ?? "",
      who.playerWord ?? "",
    ]);

    const tx: Tx = {
      query: (text, params) => client.query(text, params ? [...params] : undefined),
    };
    const out = await run(tx);

    await client.query("commit");
    inTx = false;
    return out;
  } catch (err) {
    if (inTx) {
      try {
        await client.query("rollback");
      } catch {
        poisoned = true;
      }
    }
    throw err;
  } finally {
    client.release(poisoned ? new Error("rollback failed; discarding connection") : undefined);
  }
}
