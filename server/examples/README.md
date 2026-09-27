# Example calls

Three synthetic scenes, one per outcome under the public demo policy:

| Scene | Demo decision | Why |
| --- | --- | --- |
| `pass-clear-side-wall.json` | `pass` | a long side wall, everything around the spot seen |
| `reject-garage-in-the-way.json` | `reject` | a garage door and gas meters leave no spot; both ends of the walk are real ends |
| `review-corner-not-walked.json` | `manual_review` | the walk stopped at a corner; `missing_evidence` lists the views to add |

Under the private rules the decisions can differ; that is what the private deployment is for.

## Post them all

From the repository root, with the decision per scene:

```sh
make smoke URL=https://house-scanning-server.vercel.app
make smoke URL=https://house-scanning-server-private.vercel.app KEY_FILE=server/.env.private.local
```

`make smoke` runs `server/examples/smoke.py`, which needs only Python 3. It exits 1 when any request fails. With a key it sends only to an `https://` URL (or `http://localhost`) and doesn't follow redirects, so the key can't travel in the clear or to another server.

## One call

Public deployment:

```sh
curl -s https://house-scanning-server.vercel.app/v1/placements \
  -H 'content-type: application/json' \
  --data-binary @server/examples/pass-clear-side-wall.json | python3 -m json.tool
```

Private deployment, reading the key from the git-ignored file:

```sh
curl -s https://house-scanning-server-private.vercel.app/v1/placements \
  -H "Authorization: Bearer $(sed -n 's/^HOUSESCAN_API_KEY=//p' server/.env.private.local)" \
  -H 'content-type: application/json' \
  --data-binary @server/examples/review-corner-not-walked.json | python3 -m json.tool
```

The site plan for the same scene: post it to `/v1/placements/site-plan.svg` instead and write the answer to a file (`-o plan.svg`).
