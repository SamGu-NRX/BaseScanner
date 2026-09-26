// Regenerates the result types and validator in src/contract from the result schema.
// Run `pnpm contract` after server/schemas/result.schema.json changes; contract.test.ts fails
// until the vendored copy and everything generated from it match.
import { copyFileSync, readFileSync, writeFileSync } from "node:fs";
import {
  compileResultTypes,
  compileResultValidator,
  RESULT_TYPES,
  RESULT_VALIDATOR,
  SERVER_SCHEMA,
  VENDORED_SCHEMA,
} from "./contract-lib.ts";

copyFileSync(SERVER_SCHEMA, VENDORED_SCHEMA);
const schema = JSON.parse(readFileSync(VENDORED_SCHEMA, "utf8"));
writeFileSync(RESULT_TYPES, await compileResultTypes(schema));
writeFileSync(RESULT_VALIDATOR, compileResultValidator(schema));
