/**
 * Stripe webhook signature verification, with no SDK dependency.
 *
 * TAKEN, essentially verbatim, from the practice-planner org's own
 * `api/stripe.js` (`verifyStripeSignature`). It is good code and it was already
 * paid for: constant-time comparison, a replay guard, and pure node:crypto, so
 * a webhook endpoint costs no package.
 *
 * The two things it gets right that a hand-rolled version usually does not:
 *   - it compares with timingSafeEqual rather than ===, so the comparison does
 *     not leak the signature a byte at a time
 *   - it rejects anything older than five minutes, so a captured request cannot
 *     be replayed later
 *
 * The one thing to remember at the call site: this MUST run against the RAW
 * request body. Any framework that has already parsed JSON has re-serialised
 * it, and the digest will not match — which reads as "Stripe is sending bad
 * signatures" and is the single most common way to lose an afternoon here.
 */
import { createHmac, timingSafeEqual } from "node:crypto";

const MAX_AGE_SECONDS = 300;

export function verifyStripeSignature(payload, sigHeader, secret) {
  // Stripe sends: t=<timestamp>,v1=<sig>[,v1=<sig>...]
  const parts = String(sigHeader ?? "").split(",").map((p) => p.trim());
  let ts = null;
  const v1 = [];
  for (const p of parts) {
    const [k, v] = p.split("=");
    if (k === "t") ts = v;
    if (k === "v1") v1.push(v);
  }
  if (!ts || v1.length === 0) return false;

  const age = Math.floor(Date.now() / 1000) - Number.parseInt(ts, 10);
  if (Number.isNaN(age) || age > MAX_AGE_SECONDS) return false;

  const expected = createHmac("sha256", secret)
    .update(`${ts}.${payload}`, "utf8")
    .digest("hex");
  const expectedBuf = Buffer.from(expected, "utf8");

  return v1.some((s) => {
    const sBuf = Buffer.from(s, "utf8");
    if (sBuf.length !== expectedBuf.length) return false;
    return timingSafeEqual(sBuf, expectedBuf);
  });
}

/** The raw body, unparsed. See the note above about why this matters. */
export async function readRawBody(req) {
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  return Buffer.concat(chunks).toString("utf8");
}
