/**
 * node product/api/test-stripe-signature.mjs
 *
 * Ported code is not proven code. These are the four ways a webhook endpoint
 * gets it wrong, each one asserted rather than assumed.
 */
import { createHmac } from "node:crypto";
import { verifyStripeSignature } from "./stripe-signature.js";

const SECRET = "whsec_test_ThisIsNotARealSecret";
let pass = 0, fail = 0;
const ok = (name, cond) => { cond ? pass++ : (fail++, console.log("  FAIL  " + name)); };

const sign = (payload, ts = Math.floor(Date.now() / 1000), secret = SECRET) =>
  `t=${ts},v1=` + createHmac("sha256", secret).update(`${ts}.${payload}`, "utf8").digest("hex");

const body = JSON.stringify({ id: "evt_1", type: "invoice.paid" });

ok("a genuine signature verifies", verifyStripeSignature(body, sign(body), SECRET) === true);

ok("a body altered after signing is rejected",
   verifyStripeSignature(body.replace("evt_1", "evt_2"), sign(body), SECRET) === false);

ok("a signature made with another secret is rejected",
   verifyStripeSignature(body, sign(body, undefined, "whsec_someone_else"), SECRET) === false);

ok("a six-minute-old request is rejected (replay guard)",
   verifyStripeSignature(body, sign(body, Math.floor(Date.now() / 1000) - 360), SECRET) === false);

ok("a four-minute-old request is still accepted",
   verifyStripeSignature(body, sign(body, Math.floor(Date.now() / 1000) - 240), SECRET) === true);

ok("a missing header is rejected", verifyStripeSignature(body, undefined, SECRET) === false);
ok("a header with no v1 is rejected", verifyStripeSignature(body, "t=1", SECRET) === false);
ok("a header with no t is rejected", verifyStripeSignature(body, "v1=abc", SECRET) === false);
ok("a non-numeric timestamp is rejected", verifyStripeSignature(body, "t=soon,v1=abc", SECRET) === false);

// Stripe rotates a signing secret by sending both signatures for a window.
{
  const ts = Math.floor(Date.now() / 1000);
  const old = createHmac("sha256", "whsec_old").update(`${ts}.${body}`, "utf8").digest("hex");
  const now = createHmac("sha256", SECRET).update(`${ts}.${body}`, "utf8").digest("hex");
  ok("during a secret rotation, either v1 verifies",
     verifyStripeSignature(body, `t=${ts},v1=${old},v1=${now}`, SECRET) === true);
}

// A truncated signature must not short-circuit into a length-mismatch crash.
ok("a short signature is rejected, not thrown",
   verifyStripeSignature(body, "t=" + Math.floor(Date.now() / 1000) + ",v1=ab", SECRET) === false);

console.log(`\n${pass} passed, ${fail} failed.`);
process.exit(fail ? 1 : 0);
