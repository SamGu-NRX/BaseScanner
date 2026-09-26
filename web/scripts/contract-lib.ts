import { fileURLToPath } from "node:url";
import { Ajv2020 } from "ajv/dist/2020.js";
import standaloneCode from "ajv/dist/standalone/index.js";
import { compile, type JSONSchema } from "json-schema-to-typescript";

const here = (path: string) => fileURLToPath(new URL(path, import.meta.url));

// server/schemas/result.schema.json is the source of truth; src/contract keeps a copy so the web
// app builds on its own.
export const SERVER_SCHEMA = here("../../server/schemas/result.schema.json");
export const VENDORED_SCHEMA = here("../src/contract/result.schema.json");
export const RESULT_TYPES = here("../src/contract/result.ts");
export const RESULT_VALIDATOR = here("../src/contract/validate-result.js");

const BANNER = "// Generated from result.schema.json by `pnpm contract`. Do not edit by hand.";

export function compileResultTypes(schema: JSONSchema): Promise<string> {
  return compile(schema, "PlacementResult", {
    bannerComment: BANNER,
    additionalProperties: false,
    unknownAny: true,
  });
}

/** The schema compiled to plain JavaScript, so the page validates answers without shipping Ajv
 * or evaluating code at runtime. */
export function compileResultValidator(schema: object): string {
  const ajv = new Ajv2020({ code: { source: true, esm: true } });
  return `${BANNER}\n${standaloneCode.default(ajv, ajv.compile(schema))}\n`;
}
