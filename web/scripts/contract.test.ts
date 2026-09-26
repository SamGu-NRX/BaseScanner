import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import {
  compileResultTypes,
  compileResultValidator,
  RESULT_TYPES,
  RESULT_VALIDATOR,
  SERVER_SCHEMA,
  VENDORED_SCHEMA,
} from "./contract-lib.ts";

describe("result contract", () => {
  it("generated types match the vendored schema", async () => {
    const schema = JSON.parse(readFileSync(VENDORED_SCHEMA, "utf8"));
    expect(readFileSync(RESULT_TYPES, "utf8")).toBe(await compileResultTypes(schema));
  });

  it("generated validator matches the vendored schema", () => {
    const schema = JSON.parse(readFileSync(VENDORED_SCHEMA, "utf8"));
    expect(readFileSync(RESULT_VALIDATOR, "utf8")).toBe(compileResultValidator(schema));
  });

  // #15 is stacked on #11, so server/schemas is always here; a missing file fails the test.
  it("vendored schema matches server/schemas", () => {
    expect(readFileSync(VENDORED_SCHEMA, "utf8")).toBe(readFileSync(SERVER_SCHEMA, "utf8"));
  });
});
