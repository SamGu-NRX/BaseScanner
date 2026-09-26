import { existsSync, readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import {
  compileResultTypes,
  RESULT_TYPES,
  SERVER_SCHEMA,
  VENDORED_SCHEMA,
} from "./contract-lib.ts";

describe("result contract", () => {
  it("generated types match the vendored schema", async () => {
    const schema = JSON.parse(readFileSync(VENDORED_SCHEMA, "utf8"));
    expect(readFileSync(RESULT_TYPES, "utf8")).toBe(await compileResultTypes(schema));
  });

  // server/ only exists once the placement server has merged; until then the vendored copy
  // records which server commit it came from (see README).
  it.runIf(existsSync(SERVER_SCHEMA))("vendored schema matches server/schemas", () => {
    expect(readFileSync(VENDORED_SCHEMA, "utf8")).toBe(readFileSync(SERVER_SCHEMA, "utf8"));
  });
});
