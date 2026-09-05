/**
 * lib/http.ts -- the thin shell around a handler: parse, run, and turn any
 * throw into a flat refusal.
 *
 * There is deliberately no authorization helper in this file. No
 * `requireRole()`, no `assertTeamMember()`, nothing that reads a membership. A
 * handler that needed one would be a handler doing the database's job, and the
 * database already refuses on its own. What is here is input handling: is this
 * JSON, is that path segment a uuid, and what shape does the answer take.
 */

import { ApiError, toResponse } from "./errors";
import { isUuid } from "./session";

export interface RouteCtx<P extends Record<string, string> = Record<string, string>> {
  params: Promise<P>;
}

export type Handler<P extends Record<string, string> = Record<string, string>> = (
  req: Request,
  ctx: RouteCtx<P>,
) => Promise<Response>;

/** Every exported route goes through this, so nothing can throw to the client. */
export function route<P extends Record<string, string>>(fn: Handler<P>): Handler<P> {
  return async (req, ctx) => {
    try {
      return await fn(req, ctx);
    } catch (err) {
      return toResponse(err);
    }
  };
}

export function json(data: unknown, status = 200, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      // Nothing here is cacheable: every response is scoped to one caller.
      "cache-control": "no-store",
      ...headers,
    },
  });
}

const MAX_BODY_BYTES = 1_000_000;

export async function readJson(req: Request): Promise<Record<string, unknown>> {
  const raw = await req.text();
  if (raw.length > MAX_BODY_BYTES) throw new ApiError(400);
  if (raw.trim() === "") return {};
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    throw new ApiError(400);
  }
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) throw new ApiError(400);
  return parsed as Record<string, unknown>;
}

/**
 * A path id that is not a uuid is answered exactly like a uuid that names
 * nothing: 404. Letting a malformed id fall through to Postgres would come back
 * as a 400 and hand the caller a way to tell "wrong shape" from "not yours".
 */
export async function pathUuid<P extends Record<string, string>>(ctx: RouteCtx<P>, key: keyof P & string): Promise<string> {
  const params = await ctx.params;
  const v = params[key];
  if (!isUuid(v)) throw new ApiError(404);
  return v;
}

export function str(body: Record<string, unknown>, key: string): string {
  const v = body[key];
  if (typeof v !== "string" || v.trim() === "") throw new ApiError(400);
  return v.trim();
}

export function optStr(body: Record<string, unknown>, key: string): string | null {
  const v = body[key];
  if (v === undefined || v === null) return null;
  if (typeof v !== "string") throw new ApiError(400);
  const t = v.trim();
  return t === "" ? null : t;
}

export function optUuid(body: Record<string, unknown>, key: string): string | null {
  const v = optStr(body, key);
  if (v === null) return null;
  if (!isUuid(v)) throw new ApiError(400);
  return v;
}

export function optInt(body: Record<string, unknown>, key: string): number | null {
  const v = body[key];
  if (v === undefined || v === null) return null;
  if (typeof v !== "number" || !Number.isInteger(v)) throw new ApiError(400);
  return v;
}

export function optObject(body: Record<string, unknown>, key: string): Record<string, unknown> | null {
  const v = body[key];
  if (v === undefined || v === null) return null;
  if (typeof v !== "object" || Array.isArray(v)) throw new ApiError(400);
  return v as Record<string, unknown>;
}

/**
 * An interval, kept as text and handed to Postgres to parse -- `interval '14
 * days'` is a type the database already validates, and app.issue_invite()
 * already refuses anything outside 0..90 days. Bounded here only so a caller
 * cannot post a megabyte of it.
 */
export function optInterval(body: Record<string, unknown>, key: string): string | null {
  const v = optStr(body, key);
  if (v === null) return null;
  if (v.length > 40) throw new ApiError(400);
  return v;
}
