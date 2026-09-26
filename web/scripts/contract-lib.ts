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

/** The schema as the page applies it: fields a newer server adds within the same major version
 * are accepted, as the iOS app does. The copy stays byte-identical to the server's; only what is
 * generated from it is loosened. */
export function tolerantSchema(schema: JSONSchema): JSONSchema {
  const version = schema.properties?.schema_version?.const;
  if (typeof version !== "string" || !/^\d+\.\d+$/.test(version)) {
    throw new Error(
      `result.schema.json: properties.schema_version.const should be "<major>.<minor>", got ${JSON.stringify(version)}`,
    );
  }
  const major = version.split(".")[0];
  const loose = allowAddedFields(structuredClone(schema)) as JSONSchema;
  loose.properties = {
    ...loose.properties,
    schema_version: { type: "string", pattern: `^${major}\\.\\d+$` },
  };
  return loose;
}

function allowAddedFields(node: unknown): unknown {
  if (Array.isArray(node)) {
    return node.map(allowAddedFields);
  }
  if (typeof node !== "object" || node === null) {
    return node;
  }
  return Object.fromEntries(
    Object.entries(node)
      .filter(([key, value]) => !(key === "additionalProperties" && value === false))
      .map(([key, value]) => [key, allowAddedFields(value)]),
  );
}

export function compileResultTypes(schema: JSONSchema): Promise<string> {
  return compile(tolerantSchema(schema), "PlacementResult", {
    bannerComment: BANNER,
    additionalProperties: false,
    unknownAny: true,
  });
}

/** The schema compiled to plain JavaScript, so the page validates answers without shipping Ajv
 * or evaluating code at runtime. */
export function compileResultValidator(schema: JSONSchema): string {
  const ajv = new Ajv2020({ code: { source: true, esm: true } });
  return `${BANNER}\n${standaloneCode.default(ajv, ajv.compile(tolerantSchema(schema)))}\n`;
}
