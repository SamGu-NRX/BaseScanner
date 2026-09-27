import assert from "node:assert/strict";
import { describe, test } from "node:test";
import { connectionView, initialState, looksLikePlaceholderStages, reduce, resultExpected, resultKey, stageRows, viewsToShow } from "../public/model.js";

const source = { key: "t", label: "test", kind: "synthetic" };

function selected(captureId = "cap_TEST_1") {
  return reduce(initialState(), { type: "select", mode: "live", source, captureId });
}

function run(state, ...actions) {
  return actions.reduce((s, a) => reduce(s, { session: s.session, ...a }), state);
}

const committed = (seq, paths) => ({ seq, type: "files_committed", at: "2026-09-27T00:00:00Z", data: { paths, committed: paths.length } });
const stage = (seq, name, status, extra = {}) => ({ seq, type: "stage", at: "2026-09-27T00:00:00Z", data: { stage: name, status, attempt: 1, runId: "run_a", ...extra } });
const events = (list, next = list.at(-1)?.seq ?? 0, status = "uploading") => ({ type: "events", at: 1000, body: { status, next, events: list } });

describe("events", () => {
  test("the same events delivered twice add no files and no arrivals", () => {
    const batch = events([committed(1, ["stills/a.jpg", "stills/b.jpg"])]);
    const once = run(selected(), events([]), batch);
    const twice = run(once, batch);
    assert.equal(twice.counts.acknowledged, 2);
    assert.equal(twice.arrivals.length, 1);
    assert.equal(twice.arrivalSerial, once.arrivalSerial);
    assert.equal(twice.log.length, once.log.length);
  });

  test("a path acknowledged again under a new seq counts once and animates nothing", () => {
    const s = run(selected(), events([]), events([committed(1, ["depth/k1.bin"])]), events([committed(2, ["depth/k1.bin"])]));
    assert.equal(s.counts.acknowledged, 1);
    assert.equal(s.arrivals.length, 1);
  });

  test("events apply in seq order and the cursor never moves backwards", () => {
    const s = run(selected(), events([stage(3, "validate", "done"), stage(2, "validate", "running")], 3));
    assert.equal(stageRows(s).find((r) => r.id === "validate").status, "done");
    assert.equal(s.cursor, 3);
    const older = run(s, events([], 1));
    assert.equal(older.cursor, 3);
    const ahead = run(older, events([], 9));
    assert.equal(ahead.cursor, 9);
  });

  test("an older stage update does not overwrite a newer one", () => {
    const s = run(selected(), events([stage(5, "dense", "done", { durationS: 2 })]), events([stage(4, "dense", "running")], 5));
    assert.equal(stageRows(s).find((r) => r.id === "dense").status, "done");
  });

  test("the first batch after connecting is backlog; later arrivals are not", () => {
    const s = run(selected(), events([committed(1, ["stills/a.jpg"])]), events([committed(2, ["stills/b.jpg"])]));
    assert.deepEqual(s.arrivals.map((a) => a.backlog), [true, false]);
  });

  test("unknown event types and malformed rows do not throw or change the pipeline", () => {
    const weird = [
      { seq: 1, type: "retry_finalize", at: "x", data: {} },
      { seq: 2, type: "stage", data: "not an object" },
      { seq: "3", type: "files_committed", data: { paths: ["x"] } },
      { type: "hint" },
      null,
      { seq: 4, type: "files_committed", data: { paths: [7, "stills/ok.jpg", null] } },
    ];
    const s = run(selected(), { type: "events", at: 1, body: { status: "brand_new_status", next: 4, events: weird } });
    assert.deepEqual(s.unknownTypes, ["retry_finalize"]);
    assert.equal(s.counts.acknowledged, 1);
    assert.equal(s.status, "brand_new_status");
    assert.ok(stageRows(s).every((r) => r.status === "unreported"));
    const nonsense = run(s, { type: "events", body: "garbage" }, { type: "events", body: { events: "nope" } }, { type: "status", body: null });
    assert.equal(nonsense.counts.acknowledged, 1);
  });

  test("a stage this viewer does not know is shown after the known ones", () => {
    const s = run(selected(), events([stage(1, "denoise_v2", "running")]));
    assert.equal(stageRows(s).at(-1).id, "denoise_v2");
  });

  test("a new run clears the earlier run's verdict, result and model", () => {
    const a = run(
      selected(),
      events([stage(1, "result", "done"), { seq: 2, type: "verdict_ready", at: "x", data: { runId: "run_a", kind: "eligible" } }]),
      { type: "result", body: { runId: "run_a", status: "complete", outcome: { kind: "eligible" } } },
      { type: "preview", runId: "run_a", cloud: { count: 3, kept: 3, positions: new Float32Array(9), generated: null, bounds: { min: [0, 0, 0], max: [1, 1, 1] } } },
    );
    assert.equal(a.preview.phase, "ready");
    const b = run(a, events([{ ...stage(3, "validate", "running"), data: { stage: "validate", status: "running", attempt: 1, runId: "run_b" } }]));
    assert.equal(b.currentRunId, "run_b");
    assert.equal(b.verdict, null);
    assert.equal(b.result.phase, "none");
    assert.equal(b.preview.phase, "none");
  });

  test("a late event from an earlier run does not switch the view back", () => {
    const s = run(
      selected(),
      events([stage(1, "validate", "done"), { ...stage(3, "validate", "running"), data: { stage: "validate", status: "running", attempt: 1, runId: "run_b" } }]),
      events([stage(2, "poses", "running")], 3),
    );
    assert.equal(s.currentRunId, "run_b");
    assert.equal(stageRows(s).find((r) => r.id === "poses").status, "unreported");
  });

  test("joining a capture with two runs keeps the latest run the status named", () => {
    const runB = (seq, name, status) => ({ ...stage(seq, name, status), data: { stage: name, status, attempt: 1, runId: "run_b" } });
    const s = run(
      selected(),
      { type: "status", body: { captureId: "cap_TEST_1", status: "processing", runId: "run_b" } },
      { ...events([stage(1, "validate", "done"), stage(2, "poses", "running")]), catchUp: true },
      { ...events([runB(3, "validate", "running")]), catchUp: true },
    );
    assert.equal(s.currentRunId, "run_b");
    assert.equal(stageRows(s).find((r) => r.id === "validate").status, "running");
    const withResult = run(s, { type: "result", body: { runId: "run_b", status: "complete", outcome: { kind: "eligible" } } });
    assert.equal(withResult.result.phase, "ready");
  });

  test("a run that first appears after the declared one is newer", () => {
    const runC = { seq: 9, type: "stage", at: "x", data: { stage: "validate", status: "running", attempt: 1, runId: "run_c" } };
    const s = run(selected(), { type: "status", body: { captureId: "cap_TEST_1", status: "processing", runId: "run_b" } }, events([{ ...stage(8, "validate", "done"), data: { stage: "validate", status: "done", attempt: 1, runId: "run_b" } }, runC]));
    assert.equal(s.currentRunId, "run_c");
  });

  test("a result from a run not seen yet is accepted as the latest", () => {
    const s = run(selected(), events([stage(1, "validate", "done")]), { type: "result", body: { runId: "run_z", status: "manual_review", outcome: { kind: "manual_review" } } });
    assert.equal(s.currentRunId, "run_z");
    assert.equal(s.result.phase, "ready");
  });

  test("a retake that names a new run clears the earlier run's answer at once", () => {
    const a = run(selected(), events([stage(1, "result", "done")]), { type: "result", body: { runId: "run_a", status: "complete", outcome: { kind: "eligible" } } });
    assert.equal(a.result.phase, "ready");
    const b = run(a, events([{ seq: 2, type: "retake_request", at: "x", data: { runId: "run_b", viewsNeeded: ["v1"], memberActions: [] } }], 2));
    assert.equal(b.currentRunId, "run_b");
    assert.equal(b.result.phase, "none");
  });

  test("a new run changes the result key even when the status does not", () => {
    const a = run(selected(), events([stage(1, "validate", "failed")], 1, "failed"));
    const b = run(a, events([{ ...stage(2, "validate", "failed"), data: { stage: "validate", status: "failed", attempt: 1, runId: "run_b" } }], 2, "failed"));
    assert.notEqual(resultKey(a), resultKey(b));
  });

  test("the before-you-connected total survives more batches than the arrival queue keeps", () => {
    const batches = Array.from({ length: 30 }, (_, i) => committed(i + 1, [`keyframes/k${i}.jpg`]));
    const s = run(selected(), { ...events(batches), catchUp: true });
    assert.equal(s.arrivals.length < 30, true);
    assert.equal(s.counts.backlog, 30);
  });

  test("history read while catching up counts as backlog on every page", () => {
    const s = run(selected(), { ...events([committed(1, ["stills/a.jpg"])]), catchUp: true }, { ...events([committed(2, ["stills/b.jpg"])]), catchUp: true }, { ...events([committed(3, ["stills/c.jpg"])]), catchUp: false });
    assert.deepEqual(s.arrivals.map((a) => a.backlog), [true, true, false]);
  });

  test("a new run id switches the stages shown", () => {
    const s = run(selected(), events([stage(1, "validate", "done"), { ...stage(2, "validate", "running"), data: { stage: "validate", status: "running", attempt: 1, runId: "run_b" } }]));
    assert.equal(s.currentRunId, "run_b");
    assert.equal(stageRows(s).find((r) => r.id === "validate").status, "running");
  });
});

describe("sessions", () => {
  test("callbacks from an earlier selection are ignored", () => {
    const first = selected("cap_FIRST_1");
    const oldSession = first.session;
    const second = reduce(first, { type: "select", mode: "live", source, captureId: "cap_SECOND_1" });
    const after = reduce(second, { session: oldSession, ...events([committed(1, ["stills/a.jpg"])]) });
    assert.equal(after, second);
    const stale = reduce(second, { session: oldSession, type: "result", body: { status: "complete", outcome: { kind: "eligible" } } });
    assert.equal(stale.result.phase, "none");
  });

  test("a status body for another capture is ignored", () => {
    const s = run(selected("cap_MINE_1"), { type: "status", body: { captureId: "cap_OTHER_1", status: "complete", filesRegistered: 9 } });
    assert.equal(s.status, null);
    assert.equal(s.counts.registered, null);
  });
});

describe("connection", () => {
  test("a failed contact keeps the evidence and reports reconnecting or offline", () => {
    const withData = run(selected(), events([committed(1, ["stills/a.jpg"]), stage(2, "validate", "done")]));
    const failed = run(withData, { type: "contact-failed", error: "network error", offline: false });
    assert.equal(failed.counts.acknowledged, 1);
    assert.equal(stageRows(failed)[0].status, "done");
    assert.equal(connectionView(failed, 2000).phase, "reconnecting");
    const offline = run(withData, { type: "contact-failed", error: "network error", offline: true });
    assert.equal(connectionView(offline, 2000).phase, "offline");
  });

  test("a live connection with no reply for too long reads as stale", () => {
    const s = run(selected(), { type: "contact-ok", at: 10_000 });
    assert.equal(connectionView(s, 20_000).phase, "live");
    assert.equal(connectionView(s, 60_000).phase, "stale");
  });

  test("gone and stopped keep what was already seen", () => {
    const s = run(selected(), events([committed(1, ["stills/a.jpg"])]), { type: "gone", error: "404" });
    assert.equal(s.connection.phase, "gone");
    assert.equal(s.counts.acknowledged, 1);
  });
});

describe("results", () => {
  test("verdict_ready alone claims no outcome and no model", () => {
    const s = run(selected(), events([{ seq: 1, type: "verdict_ready", at: "x", data: { runId: "run_a", kind: "eligible" } }]));
    assert.ok(resultExpected(s));
    assert.equal(s.result.phase, "none");
    assert.equal(s.preview.phase, "none");
  });

  test("a minimal result while processing stays pending", () => {
    const s = run(selected(), { type: "result", body: { runId: "run_a", status: "processing", outcome: null, viewsNeeded: [], memberActions: [] } });
    assert.equal(s.result.phase, "pending");
  });

  test("a model with zero points is empty, not ready", () => {
    const withResult = run(selected(), { type: "result", body: { runId: "run_a", status: "manual_review", outcome: { kind: "manual_review" } } });
    const s = run(withResult, { type: "preview", runId: "run_a", cloud: { count: 0, kept: 0, positions: new Float32Array(), generated: null, bounds: null } });
    assert.equal(s.preview.phase, "empty");
  });

  test("an expired capture asks for its result", () => {
    assert.ok(resultExpected(run(selected(), events([], 0, "expired"))));
  });

  test("a complete status without an outcome is still pending", () => {
    const s = run(selected(), { type: "result", body: { runId: "run_a", status: "complete", outcome: null } });
    assert.equal(s.result.phase, "pending");
    const failed = run(selected(), { type: "result", body: { runId: "run_a", status: "failed", outcome: null } });
    assert.equal(failed.result.phase, "ready");
  });

  test("a model for a run other than the result's is dropped", () => {
    const withResult = run(selected(), { type: "result", body: { runId: "run_a", status: "complete", outcome: { kind: "eligible" } } });
    const s = run(withResult, { type: "preview", runId: "run_b", cloud: { count: 5, kept: 5, positions: new Float32Array(15), generated: null, bounds: null } });
    assert.equal(s.preview.phase, "none");
  });

  test("an unreadable model is unsupported", () => {
    const s = run(selected(), { type: "preview-error", runId: "run_a", unsupported: true, error: "not a PLY file" });
    assert.equal(s.preview.phase, "unsupported");
  });
});

test("a stage left running when the capture settles shows no reported end", () => {
  const s = run(selected(), events([stage(1, "validate", "running")], 1, "failed"));
  assert.equal(stageRows(s)[0].status, "unended");
  const open = run(selected(), events([stage(1, "validate", "running")], 1, "processing"));
  assert.equal(stageRows(open)[0].status, "running");
});

test("requested views show before any result exists, and the result's own list wins once it arrives", () => {
  const retake = run(selected(), events([{ seq: 1, type: "retake_request", at: "x", data: { runId: "run_a", viewsNeeded: ["vn3"], memberActions: [] } }]));
  assert.equal(retake.result.body, null);
  assert.deepEqual(viewsToShow(retake), [{ id: "vn3", title: null }]);
  const withResult = run(retake, { type: "result", body: { runId: "run_a", status: "needs_views", outcome: null, viewsNeeded: [{ id: "vn3", prompt: { title: "Show the ground left of the meter", body: "b" } }] } });
  assert.deepEqual(viewsToShow(withResult), [{ id: "vn3", title: "Show the ground left of the meter" }]);
});

test("a new run clears the previous run's retake and any result read without a body", () => {
  const a = run(selected(), events([{ seq: 1, type: "retake_request", at: "x", data: { runId: "run_a", viewsNeeded: ["vn3"], memberActions: [] } }]), { type: "result-loading" });
  assert.equal(a.result.phase, "loading");
  const b = run(a, events([{ ...stage(2, "validate", "running"), data: { stage: "validate", status: "running", attempt: 1, runId: "run_b" } }], 2));
  assert.equal(b.retake, null);
  assert.deepEqual(viewsToShow(b), []);
  assert.equal(b.result.phase, "none");
});

test("discarding an older run's result keeps the current run's pending result pending", () => {
  const s = run(
    selected(),
    events([stage(1, "validate", "done"), { ...stage(2, "validate", "running"), data: { stage: "validate", status: "running", attempt: 1, runId: "run_b" } }]),
    { type: "result", body: { runId: "run_b", status: "processing", outcome: null } },
    { type: "result", body: { runId: "run_a", status: "complete", outcome: { kind: "eligible" } } },
  );
  assert.equal(s.result.phase, "pending");
  assert.equal(s.result.body.runId, "run_b");
});

test("a late retake from a superseded run asks nothing of the current run", () => {
  const s = run(
    selected(),
    events([stage(1, "validate", "done"), { ...stage(2, "validate", "running"), data: { stage: "validate", status: "running", attempt: 1, runId: "run_b" } }]),
    events([{ seq: 3, type: "retake_request", at: "x", data: { runId: "run_a", viewsNeeded: ["vn_old"], memberActions: [] } }], 3),
  );
  assert.equal(s.currentRunId, "run_b");
  assert.deepEqual(viewsToShow(s), []);
});

test("each accepted result is a new revision, and a same-run model stays up while it reloads", () => {
  const cloud = { count: 3, kept: 3, positions: new Float32Array(9), generated: null, bounds: { min: [0, 0, 0], max: [1, 1, 1] } };
  const a = run(selected(), { type: "result", body: { runId: "run_a", status: "complete", outcome: { kind: "eligible" }, previewUrl: "withheld-by-viewer-relay" } }, { type: "preview", runId: "run_a", cloud });
  const b = run(a, { type: "result", body: { runId: "run_a", status: "complete", outcome: { kind: "eligible" }, previewUrl: "withheld-by-viewer-relay" } }, { type: "preview-loading", runId: "run_a" });
  assert.equal(b.result.revision, a.result.revision + 1);
  assert.equal(b.preview.phase, "ready");
});

test("a retake names the views the server asked for", () => {
  const s = run(selected(), events([{ seq: 1, type: "retake_request", at: "x", data: { runId: "run_a", viewsNeeded: ["vn3", "vn4"], memberActions: [] } }]));
  assert.deepEqual(s.retake.views, ["vn3", "vn4"]);
  assert.match(s.log.at(-1).text, /vn3, vn4/);
});

test("a refreshed result without a preview drops the earlier model", () => {
  const cloud = { count: 3, kept: 3, positions: new Float32Array(9), generated: null, bounds: { min: [0, 0, 0], max: [1, 1, 1] } };
  const shown = run(selected(), { type: "result", body: { runId: "run_a", status: "complete", outcome: { kind: "eligible" }, previewUrl: "withheld-by-viewer-relay" } }, { type: "preview", runId: "run_a", cloud });
  assert.equal(shown.preview.phase, "ready");
  const refreshed = run(shown, { type: "result", body: { runId: "run_a", status: "complete", outcome: { kind: "eligible" }, previewUrl: "" } });
  assert.equal(refreshed.preview.phase, "none");
});

test("a model whose points are all unusable is empty, not ready", () => {
  const withResult = run(selected(), { type: "result", body: { runId: "run_a", status: "complete", outcome: { kind: "eligible" } } });
  const s = run(withResult, { type: "preview", runId: "run_a", cloud: { count: 2, kept: 0, positions: new Float32Array(0), generated: null, bounds: null } });
  assert.equal(s.preview.phase, "empty");
});

test("a finished stage with no reported duration keeps the placeholder warning off", () => {
  const quick = ["validate", "poses", "scale"].map((n, i) => stage(i + 1, n, "done", { durationS: 0.01 }));
  assert.ok(!looksLikePlaceholderStages(run(selected(), events([...quick, stage(4, "dense", "done")]))));
});

test("a failed refresh keeps the result already shown", () => {
  const s = run(selected(), { type: "result", body: { runId: "run_a", status: "manual_review", outcome: { kind: "manual_review" } } }, { type: "result-loading" }, { type: "result-error", error: "network error" });
  assert.equal(s.result.phase, "ready");
  assert.equal(s.result.body.outcome.kind, "manual_review");
  assert.equal(s.result.error, "network error");
});

test("the eligible illustration leaves no check unsure", async () => {
  const { resultBody } = await import("../public/scenario.js");
  const body = resultBody("complete", "complete");
  assert.equal(body.outcome.kind, "eligible");
  assert.ok(body.criteria.every((c) => c.outcome === "pass"));
});

test("near-zero stage durations are flagged as placeholders", () => {
  const quick = ["validate", "poses", "scale"].map((n, i) => stage(i + 1, n, "done", { durationS: 0.01 }));
  assert.ok(looksLikePlaceholderStages(run(selected(), events(quick))));
  const real = ["validate", "poses", "scale"].map((n, i) => stage(i + 1, n, "done", { durationS: 3 }));
  assert.ok(!looksLikePlaceholderStages(run(selected(), events(real))));
});

test("the illustration states no clearance thresholds of its own", async () => {
  const { resultBody } = await import("../public/scenario.js");
  const criteria = resultBody("complete", "complete").criteria;
  assert.ok(criteria.length > 0);
  assert.ok(criteria.every((c) => !("thresholdFt" in c)), "thresholds belong in sourced rules files");
});
