# web

The placement review page: pick a sample or drop a scan, and see where the Base Power battery goes and why. It calls the placement server's `POST /v1/placements` (see `server/README.md`) and shows the decision, the spot and cable run, the site plan, every check with its reason, and the views still missing.

## Run

Requires Node 24 or later (`.node-version`) and the pnpm pinned in `package.json`.

```sh
pnpm install
pnpm dev          # http://localhost:5173
```

The page talks to the server at `VITE_PLACEMENT_API`, default `/api`. In `pnpm dev` and `pnpm preview`, `/api` is proxied to `PLACEMENT_SERVER` (default `http://localhost:8000`), so start the server first: `cd server && uv run uvicorn api:app --port 8000`. A reviewer can point the page at another server with **Change**; the choice is kept in the browser. `?sample=<id>` opens a sample directly, so a link shares an answer.

Without a reachable server, the bundled samples can still show the answer the server gave them when it was recorded; the page says so ("Saved answer").

| Command          | What it does                                           |
| ---------------- | ------------------------------------------------------ |
| `pnpm dev`       | Vite dev server                                        |
| `pnpm build`     | `tsc -b`, then `vite build` into `dist/`               |
| `pnpm preview`   | Serve `dist/` with the same `/api` proxy               |
| `pnpm check`     | lint, typecheck, test, build; what CI runs             |
| `pnpm contract`  | Regenerate the result types from the server's schema   |

## The result contract

`src/contract/result.schema.json` is a copy of `server/schemas/result.schema.json`, and `src/contract/result.ts` is generated from it by `pnpm contract`. Answers are validated against the schema at runtime, so a server that breaks the contract shows a specific error instead of a broken page. `scripts/contract.test.ts` fails when the generated types don't match the copy, or, when `server/` is present, when the copy doesn't match the server's schema. After the server's schema changes, run `pnpm contract` and commit both files.

The samples in `src/samples/` are synthetic. `scripts/record_samples.py` builds their scenes and records the server's answers (`cd server && PYTHONPATH=. uv run python ../web/scripts/record_samples.py`); rerun it when the solver changes. Generated and recorded files are excluded from Biome so they stay byte-identical to what produced them.

## Conventions

- The server reports feet; `src/lib/format.ts` says them the way people do ("2 ft 9 in right of the meter"). `src/lib/units.ts` converts ARKit's meters.
- TypeScript runs in strict mode with `noUncheckedIndexedAccess`. Tests sit next to their source as `*.test.ts`.
- Use synthetic data only. The repository is public, so never commit real home photos, addresses or meter numbers.
