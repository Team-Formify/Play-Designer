/**
 * Resolve extensionless relative imports to .ts, so `node --experimental-strip-types`
 * can run these files directly.
 *
 * The imports here are extensionless because that is what the planner's bundler
 * wants and these files are written to drop into his repo unchanged — his
 * `scripts/ts-loader.mjs` does the same job for the same reason. Node strips the
 * types natively but its resolver still wants an extension, so the runner
 * adapts rather than the source.
 *
 *     node --experimental-strip-types --import ./bridge/register-ts.mjs bridge/prove.ts
 */
import { dirname, resolve as resolvePath } from "node:path";
import { existsSync } from "node:fs";
import { fileURLToPath, pathToFileURL } from "node:url";

const CANDIDATES = [".ts", ".tsx", "/index.ts"];

export function resolve(specifier, context, next) {
  if (specifier.startsWith(".") && context.parentURL?.startsWith("file:")) {
    const base = resolvePath(dirname(fileURLToPath(context.parentURL)), specifier);
    if (!existsSync(base)) {
      for (const ext of CANDIDATES) {
        if (existsSync(base + ext)) return next(pathToFileURL(base + ext).href, context);
      }
    }
  }
  return next(specifier, context);
}
