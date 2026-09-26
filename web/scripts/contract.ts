// Regenerates src/contract/result.ts from the result schema.
// Run `pnpm contract` after server/schemas/result.schema.json changes; contract.test.ts fails
// until the vendored copy and the generated types match it.
import { copyFileSync, existsSync, readFileSync, writeFileSync } from "node:fs";
import {
  compileResultTypes,
  RESULT_TYPES,
  SERVER_SCHEMA,
  VENDORED_SCHEMA,
} from "./contract-lib.ts";

if (existsSync(SERVER_SCHEMA)) {
  copyFileSync(SERVER_SCHEMA, VENDORED_SCHEMA);
}
const schema = JSON.parse(readFileSync(VENDORED_SCHEMA, "utf8"));
writeFileSync(RESULT_TYPES, await compileResultTypes(schema));
