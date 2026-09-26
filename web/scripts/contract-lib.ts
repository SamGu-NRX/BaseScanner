import { fileURLToPath } from "node:url";
import { compile, type JSONSchema } from "json-schema-to-typescript";

const here = (path: string) => fileURLToPath(new URL(path, import.meta.url));

// server/schemas/result.schema.json is the source of truth; src/contract keeps a copy so the web
// app builds on its own.
export const SERVER_SCHEMA = here("../../server/schemas/result.schema.json");
export const VENDORED_SCHEMA = here("../src/contract/result.schema.json");
export const RESULT_TYPES = here("../src/contract/result.ts");

export function compileResultTypes(schema: JSONSchema): Promise<string> {
  return compile(schema, "PlacementResult", {
    bannerComment: "// Generated from result.schema.json by `pnpm contract`. Do not edit by hand.",
    additionalProperties: false,
    unknownAny: true,
  });
}
