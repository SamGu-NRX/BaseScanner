#!/usr/bin/env node
// Starts the viewer on 127.0.0.1. See README.md for the options.

import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";
import { createViewerServer } from "./relay.js";
import { createSyntheticApi } from "./synthetic-api.js";

const { values } = parseArgs({
  options: {
    port: { type: "string", default: "4317" },
    api: { type: "string" },
    synthetic: { type: "boolean", default: false },
    "local-api": { type: "string" },
    quiet: { type: "boolean", default: false },
  },
});

const upstreams = {};
// The deployed API's address is not in this public repository; pass it at startup.
const api = values.api ?? process.env.CAPTURE_API_URL;
if (api) {
  const url = new URL(api);
  if (url.protocol !== "https:") throw new Error("--api must be an https URL ending in /v1");
  // Signed preview URLs from the deployed API point at Google Cloud Storage.
  upstreams.api = { base: url.href.replace(/\/$/, ""), label: "Capture API", kind: "backend", previewHosts: ["storage.googleapis.com"] };
}
if (values["local-api"]) {
  const url = new URL(values["local-api"]);
  if (!["127.0.0.1", "localhost"].includes(url.hostname)) throw new Error("--local-api must be a loopback URL, such as the iOS kit's fake API");
  upstreams.local = { base: url.href.replace(/\/$/, ""), label: `Local API ${url.host}`, kind: "local" };
}
let synthetic = null;
if (values.synthetic) {
  synthetic = createSyntheticApi();
  const port = await synthetic.listen(0);
  upstreams.synthetic = { base: `http://127.0.0.1:${port}/v1`, label: "Synthetic local API", kind: "synthetic" };
}
if (Object.keys(upstreams).length === 0) {
  console.log("No live source: pass --api <https URL ending in /v1>, --synthetic or --local-api. Replay still works.");
}

const viewer = createViewerServer({
  upstreams,
  publicDir: join(dirname(fileURLToPath(import.meta.url)), "public"),
  log: values.quiet ? () => {} : (line) => console.log(`${new Date().toISOString().slice(11, 19)} ${line}`),
});
const port = await viewer.listen(Number(values.port));
console.log(`Viewer: http://127.0.0.1:${port}/`);
for (const [key, up] of Object.entries(upstreams)) console.log(`  source ${key}: ${up.label} (${new URL(up.base).origin})`);
if (synthetic) console.log(`  try: http://127.0.0.1:${port}/?mode=live&source=synthetic&capture=cap_SYNTH_COMPLETE_${Date.now().toString(36).toUpperCase()}`);

const stop = async () => {
  await Promise.all([viewer.close(), synthetic?.close()]);
  process.exit(0);
};
process.on("SIGINT", stop);
process.on("SIGTERM", stop);
