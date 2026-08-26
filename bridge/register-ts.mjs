/** Installs ts-loader.mjs, so bridge/prove.ts can run. See that file for why. */
import { register } from "node:module";
register("./ts-loader.mjs", import.meta.url);
