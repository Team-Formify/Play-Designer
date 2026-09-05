/**
 * lib/errors.ts -- refusals that answer the same way whatever they are refusing.
 *
 * THE PROPERTY: a refusal must not tell the caller whether the row exists. If
 * "not found" and "not yours" differ by one byte, the API is an existence
 * oracle -- point it at a list of uuids and it enumerates another league's
 * teams without ever returning one of their rows. So there is a fixed list of
 * responses here, each a flat string, and nothing from Postgres reaches the
 * wire: not `message`, not `detail`, not `constraint`, not `hint`, not `where`,
 * not the parameters that were echoed into a raise.
 *
 * Postgres is helpful in exactly the way that hurts here. A check violation
 * names the constraint and prints the row; a raise inside a security definer
 * function quotes its arguments ("role x is not a team role", "invitation
 * expired on ..."); a unique violation prints the colliding key. All of that is
 * a description of data the caller was just refused.
 *
 * The mapping:
 *   42501  insufficient_privilege -> 403 forbidden   (RLS, a missing EXECUTE
 *                                                     grant, or a raise from a
 *                                                     definer function)
 *   23505  unique_violation       -> 409 conflict
 *   23514/23503/23502/23P01       -> 400 rejected    (constraint contents dropped)
 *   22023/22P02/22001/22007/22008 -> 400 rejected    (bad argument, bad uuid)
 *   40001/40P01                   -> 409 conflict    (serialisation, retryable)
 *   57014  query_canceled         -> 503 unavailable (statement timeout)
 *   anything else                 -> 500 server error, logged, never described
 *
 * The full error goes to the server log, where the caller cannot read it. That
 * is the only copy anybody needs.
 */

export type ApiStatus = 400 | 401 | 403 | 404 | 409 | 500 | 501 | 503;

/** The complete vocabulary of refusals. Flat, and identical between causes. */
const FLAT: Record<ApiStatus, string> = {
  400: "rejected",
  401: "unauthorized",
  403: "forbidden",
  404: "not found",
  409: "conflict",
  500: "server error",
  501: "not implemented",
  503: "unavailable",
};

export class ApiError extends Error {
  readonly status: ApiStatus;
  /** Overrides the flat message. Only ever set to another constant in this repo. */
  readonly flat: string;

  constructor(status: ApiStatus, flat?: string) {
    super(flat ?? FLAT[status]);
    this.name = "ApiError";
    this.status = status;
    this.flat = flat ?? FLAT[status];
  }
}

export const notFound = (): ApiError => new ApiError(404);
export const forbidden = (): ApiError => new ApiError(403);
export const rejected = (): ApiError => new ApiError(400);

interface PgLike {
  code?: string;
  message?: string;
  constraint?: string;
  detail?: string;
}

function pgCode(err: unknown): string | null {
  if (typeof err !== "object" || err === null) return null;
  const code = (err as PgLike).code;
  return typeof code === "string" ? code : null;
}

function statusForPg(code: string): ApiStatus {
  switch (code) {
    case "42501": // insufficient_privilege: RLS refused, or no EXECUTE grant
      return 403;
    case "23505": // unique_violation
    case "40001": // serialization_failure
    case "40P01": // deadlock_detected
      return 409;
    case "23514": // check_violation
    case "23503": // foreign_key_violation
    case "23502": // not_null_violation
    case "23P01": // exclusion_violation
    case "22023": // invalid_parameter_value -- our own raises use this
    case "22P02": // invalid_text_representation (a malformed uuid)
    case "22001": // string_data_right_truncation
    case "22007": // invalid_datetime_format
    case "22008": // datetime_field_overflow
      return 400;
    case "57014": // query_canceled -- statement_timeout
      return 503;
    default:
      return 500;
  }
}

/**
 * Turn anything thrown into the response the caller sees. The only branch that
 * reads the error at all reads its `code`; the text is logged, never returned.
 */
export function toResponse(err: unknown): Response {
  let status: ApiStatus = 500;

  if (err instanceof ApiError) {
    status = err.status;
    return flatResponse(status, err.flat);
  }

  const code = pgCode(err);
  if (code) {
    status = statusForPg(code);
    // Server-side only. A 500 with no cause in the log is how a real bug hides.
    console.error(
      `[api] postgres ${code} -> ${status}:`,
      (err as PgLike).message ?? "",
      (err as PgLike).constraint ? `constraint=${(err as PgLike).constraint}` : "",
    );
  } else {
    console.error("[api] unhandled:", err);
  }

  return flatResponse(status, FLAT[status]);
}

export function flatResponse(status: ApiStatus, flat: string): Response {
  return new Response(JSON.stringify({ error: flat }), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
    },
  });
}
