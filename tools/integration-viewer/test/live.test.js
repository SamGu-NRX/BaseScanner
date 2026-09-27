// Runs the browser's live follower in Node against relay + synthetic API, with the scenario clock
// sped up. This is the same code path a page uses, minus the DOM.

import assert from "node:assert/strict";
import { dirname, join } from "node:path";
import { after, before, test } from "node:test";
import { fileURLToPath } from "node:url";
import { followCapture } from "../public/live.js";
import { initialState, reduce, stageRows } from "../public/model.js";
import { createViewerServer } from "../relay.js";
import { createSyntheticApi } from "../synthetic-api.js";

let synthetic;
let viewer;
let origin;

before(async () => {
  synthetic = createSyntheticApi({ speed: 40 });
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

function harness(captureId) {
  let state = reduce(initialState(), { type: "select", mode: "live", source: { key: "synthetic", label: "s", kind: "synthetic" }, captureId });
  const actions = [];
  const dispatch = (action) => {
    actions.push(action);
    state = reduce(state, action);
  };
  const follower = followCapture({
    sourceKey: "synthetic",
    captureId,
    session: state.session,
    dispatch,
    getState: () => state,
    fetchImpl: (path, init) => fetch(origin + path, init),
    sleep: (ms, signal) => new Promise((resolve) => {
      const t = setTimeout(resolve, ms / 20);
      signal.addEventListener("abort", () => clearTimeout(t), { once: true });
    }),
    online: () => true,
  });
  return { follower, actions, get state() { return state; }, set state(s) { state = s; } };
}

async function until(check, ms = 8000) {
  const deadline = Date.now() + ms;
  while (Date.now() < deadline) {
    if (check()) return;
    await new Promise((r) => setTimeout(r, 25));
  }
  throw new Error("timed out");
}

test("follows a synthetic capture to its result and final model", async () => {
  const h = harness("cap_SYNTH_COMPLETE_L1");
  await until(() => h.state.preview.phase === "ready");
  h.follower.stop();
  assert.equal(h.state.status, "complete");
  assert.equal(h.state.counts.acknowledged, 102);
  assert.ok(stageRows(h.state).every((r) => r.status === "done"));
  assert.equal(h.state.result.body.outcome.kind, "eligible");
  assert.ok(h.state.preview.cloud.count > 1000);
  assert.equal(h.state.connection.phase, "stopped");
});

test("rides out a dropped connection without losing or repeating events", async () => {
  const h = harness("cap_SYNTH_DROPOUT_L2");
  await until(() => h.state.preview.phase === "ready", 12_000);
  h.follower.stop();
  assert.ok(h.actions.some((a) => a.type === "contact-failed"), "the outage was reported");
  assert.equal(h.state.counts.acknowledged, 102);
  const fileEvents = h.state.log.filter((e) => e.kind === "files").length;
  const seqs = h.state.log.map((e) => e.seq).filter((q) => q != null);
  assert.equal(new Set(seqs).size, seqs.length, "no event logged twice");
  assert.ok(fileEvents > 0);
});

test("reports a rejected packet as a failure with no result claimed", async () => {
  const h = harness("cap_SYNTH_FAILED_L3");
  await until(() => h.state.status === "failed" && h.state.result.phase === "ready");
  h.follower.stop();
  assert.equal(h.state.failures[0].code, "synthetic_depth_size");
  assert.equal(h.state.result.body.outcome, null);
  assert.equal(h.state.preview.phase, "none");
});

test("an unknown capture ends as gone", async () => {
  const h = harness("cap_SYNTH_UNKNOWN_L4");
  await until(() => h.state.connection.phase === "gone");
  await h.follower.done;
});

test("after a switch, the old follower cannot write into the new capture", async () => {
  const h = harness("cap_SYNTH_COMPLETE_L5");
  await until(() => h.state.counts.acknowledged > 0);
  h.state = reduce(h.state, { type: "select", mode: "live", source: { key: "synthetic", label: "s", kind: "synthetic" }, captureId: "cap_SYNTH_COMPLETE_L6" });
  const switched = h.state;
  await new Promise((r) => setTimeout(r, 400));
  assert.equal(h.state, switched, "no action from the old session changed state");
  assert.ok(h.actions.length > 0);
  h.follower.stop();
});

test("a finished capture is polled at a bounded rate, even when the API ignores wait", async () => {
  // The synthetic API answers at once after its timeline ends, like an API that ignores `wait`.
  const h = harness("cap_SYNTH_COMPLETE_L7");
  await until(() => h.state.preview.phase === "ready");
  const before = h.actions.filter((a) => a.type === "events").length;
  await new Promise((r) => setTimeout(r, 500));
  const polls = h.actions.filter((a) => a.type === "events").length - before;
  h.follower.stop();
  // The harness divides sleeps by 20, so the 1 s floor becomes 50 ms: about 10 polls, not thousands.
  assert.ok(polls <= 15, `polled ${polls} times in 500 ms`);
});
