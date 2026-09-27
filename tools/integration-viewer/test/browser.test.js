// Runs the page in headless Chrome under the conditions an embedded preview panel produced:
// scripts and timers ran, but no animation or transition advanced, and frames were drawn only
// when the host captured the panel. Many server batches then reach the page in one frame. The
// page must still show every count and state the server reported. Skipped when no Chrome exists.

import assert from "node:assert/strict";
import { dirname, join } from "node:path";
import { after, before, test } from "node:test";
import { fileURLToPath } from "node:url";
import { createViewerServer } from "../relay.js";
import { createSyntheticApi } from "../synthetic-api.js";
import { findChrome, launchChrome } from "./support/chrome.js";

const chromePath = findChrome();
let synthetic;
let viewer;
let origin;

before(async () => {
  synthetic = createSyntheticApi({ speed: 2 });
  const sPort = await synthetic.listen(0);
  viewer = createViewerServer({
    upstreams: { synthetic: { base: `http://127.0.0.1:${sPort}/v1`, label: "Synthetic", kind: "synthetic" } },
    publicDir: join(dirname(fileURLToPath(import.meta.url)), "..", "public"),
  });
  origin = `http://127.0.0.1:${await viewer.listen(0)}`;
});

after(async () => {
  await viewer.close();
  await synthetic.close();
});

// Frames run only when the test calls __flushFrames, the way a panel paints only when captured.
const RARE_FRAMES = `
  window.__frames = [];
  window.requestAnimationFrame = (cb) => window.__frames.push(cb);
  window.cancelAnimationFrame = () => {};
  window.__flushFrames = () => { const due = window.__frames; window.__frames = []; const t = performance.now(); for (const cb of due) cb(t); };
`;

const READ_PAGE = `(() => {
  window.__flushFrames();
  const last = [...document.querySelectorAll("#log li .s")].map((e) => Number(e.textContent.slice(1))).filter(Boolean).at(-1) ?? 0;
  const done = document.querySelector('.st[data-status="done"] .st-mark');
  return {
    lastSeq: last,
    ack: Number(document.querySelector("#ack").textContent),
    kinds: ["k-photo", "k-depth", "k-other"].map((id) => Number(document.getElementById(id).textContent)).reduce((a, b) => a + b, 0),
    status: document.querySelector("#server-state").textContent,
    doneMark: done ? getComputedStyle(done).backgroundColor : null,
  };
})()`;

test("with the animation clock stopped, counts and stage marks still follow the server", { skip: chromePath ? false : "no Chrome found; set CHROME_PATH" }, async () => {
  const chrome = await launchChrome(chromePath);
  try {
    await chrome.send("Emulation.setDeviceMetricsOverride", { width: 1280, height: 800, deviceScaleFactor: 1, mobile: false });
    await chrome.send("Page.enable");
    await chrome.send("Animation.enable");
    await chrome.send("Animation.setPlaybackRate", { playbackRate: 0 });
    await chrome.send("Page.addScriptToEvaluateOnNewDocument", { source: RARE_FRAMES });
    const capture = `cap_SYNTH_COMPLETE_B${Date.now()}`;
    await chrome.send("Page.navigate", { url: `${origin}/?mode=live&source=synthetic&capture=${capture}` });

    // Uploads finish about 4.5 s in at double speed; a frame every 3 s sees them in two or three batches.
    const samples = [];
    let doneSince = null;
    let doneMark = null;
    const started = Date.now();
    while (Date.now() - started < 15_000) {
      await new Promise((r) => setTimeout(r, 3000));
      const page = await chrome.evaluate(READ_PAGE);
      samples.push(page);
      if (page.doneMark && doneSince == null) doneSince = Date.now();
      else if (doneSince) {
        doneMark = page.doneMark;
        break;
      }
    }

    // The truth: unique acknowledged paths among events up to the last seq the page had drawn.
    const reply = await fetch(`${origin}/relay/synthetic/captures/${capture}/events?after=0&wait=0`);
    const events = (await reply.json()).events;
    const pathsThrough = (seq) => new Set(events.filter((e) => e.type === "files_committed" && e.seq <= seq).flatMap((e) => e.data.paths)).size;

    // Each frame draws the log and the counts together, so they must agree in that frame.
    const wrong = samples
      .map((s) => ({ seq: s.lastSeq, expected: pathsThrough(s.lastSeq), shown: s.ack, kinds: s.kinds }))
      .filter((s) => s.shown !== s.expected || s.kinds !== s.expected);
    assert.deepEqual(wrong, [], "file counts disagreed with the events the same frame showed");
    assert.ok(samples.at(-1).ack > 0);

    assert.ok(doneSince, "no stage finished within the test window");
    // A transparent computed colour ends in "/ 0)" (oklab) or ", 0)" (rgba).
    assert.doesNotMatch(doneMark, /(\/ 0\)|, 0\))$/, `a finished stage still showed an empty marker (${doneMark})`);
  } finally {
    await chrome.close();
  }
});
