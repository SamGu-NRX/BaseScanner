# web

The placement review page: pick a sample or drop a scan, and see where the Base Power battery goes and why. It calls the placement server's `POST /v1/placements` (see `server/README.md`) and shows the decision, the spot and cable run, the site plan, every check with its reason, and the views still missing. The site plan comes from `POST /v1/placements/site-plan.svg`, asked for only after an answer arrives, so a scene the server refuses is sent once.

## Run

Requires Node 24 or later (`.node-version`) and the pnpm pinned in `package.json`.

```sh
pnpm install
pnpm dev          # http://localhost:5173
```

The page talks to the server at `VITE_PLACEMENT_API`, default `/api`. In `pnpm dev` and `pnpm preview`, `/api` is proxied to `PLACEMENT_SERVER` (default `http://localhost:8000`), so start the server first: `cd server && uv run uvicorn api:app --port 8000`. A reviewer can point the page at another server with **Change**; the choice is kept in the browser. `?sample=<id>` opens a sample directly, so a link shares an answer.

Vercel previews of this page are built with `VITE_PLACEMENT_API=https://house-scanning-server.vercel.app`, the hosted server (public rules only; see `server/README.md`). Its host refuses request bodies over 4.5 MB without the headers a browser needs to read the refusal, so the page refuses larger files itself; send `scene.json` or a zip without the photos. A page served over https can't call an http server; the page says so when one is entered.

Without a reachable server, the bundled samples can still show the answer the server gave them when it was recorded; the page says so ("Saved answer").

| Command          | What it does                                           |
| ---------------- | ------------------------------------------------------ |
| `pnpm dev`       | Vite dev server                                        |
| `pnpm build`     | `tsc -b`, then `vite build` into `dist/`               |
| `pnpm preview`   | Serve `dist/` with the same `/api` proxy               |
| `pnpm check`     | lint, typecheck, test, build; what CI runs             |
| `pnpm contract`  | Regenerate the result types from the server's schema   |

## The result contract

`src/contract/result.schema.json` is a copy of `server/schemas/result.schema.json`, and `src/contract/result.ts` is generated from it by `pnpm contract`. Answers are validated against the schema at runtime, so a server that breaks the contract shows a specific error instead of a broken page. `scripts/contract.test.ts` fails when the generated files don't match the copy or the copy doesn't match the server's schema; CI runs it when either side changes. After the server's schema changes, run `pnpm contract` and commit the results.

The page accepts answers with fields it doesn't know, as long as `schema_version` has the same major version (`1.x`), so a server that adds a field doesn't break a deployed page. The copy stays identical to the server's; only the generated types and validator are loosened (`tolerantSchema` in `scripts/contract-lib.ts`).

The samples in `src/samples/` are synthetic. `scripts/record_samples.py` builds their scenes and records the server's answers under the public rules, as the hosted server gives them (`cd server && PYTHONPATH=. uv run python ../web/scripts/record_samples.py`); rerun it when the solver changes. Generated and recorded files are excluded from Biome so they stay byte-identical to what produced them.

## Conventions

- The server reports feet; `src/lib/format.ts` says them the way people do ("2 ft 9 in right of the meter"). `src/lib/units.ts` converts ARKit's meters.
- TypeScript runs in strict mode with `noUncheckedIndexedAccess`. Tests sit next to their source as `*.test.ts`.
- Use synthetic data only. The repository is public, so never commit real home photos, addresses or meter numbers.
