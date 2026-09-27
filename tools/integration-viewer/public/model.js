// Viewer state. A pure reducer: every network callback and every replay step becomes an action,
// and the view renders whatever state results. Nothing here reads the clock or the network.
//
// Each capture selection gets a new `session` number. Every other action carries the session it
// was issued under, and the reducer drops actions from an older session. That is what keeps a
// slow long-poll for capture A from writing into the view after the user switched to capture B.

/** Server stage ids in pipeline order, with the words the viewer shows for each. */
export const STAGES = [
  ["validate", "Checking the packet"],
  ["poses", "Placing photos in 3D"],
  ["objects", "Finding meter and obstacles"],
  ["reads", "Reading the meter"],
  ["scale", "Setting real-world scale"],
  ["dense", "Building the wall surface"],
  ["coverage", "Mapping what was seen"],
  ["scene", "Assembling the wall model"],
  ["objects_3d", "Locating objects in 3D"],
  ["criteria", "Checking placement rules"],
  ["result", "Writing the answer"],
];

const KNOWN_EVENTS = new Set([
  "files_committed",
  "hint",
  "capture_check",
  "stage",
  "verdict_ready",
  "retake_request",
  "review_started",
  "review_completed",
  "failed",
  "confirmation",
]);

/** Statuses after which the server has written, or will not write, a result. */
export const RESULT_STATUSES = new Set(["needs_views", "complete", "manual_review", "failed", "expired"]);

const LOG_LIMIT = 60;
const ARRIVAL_LIMIT = 24;

export function initialState() {
  return {
    session: 0,
    mode: "idle", // "idle" | "live" | "replay"
    source: null, // { key, label, kind: "backend" | "synthetic" | "replay" }
    captureId: null,
    connection: { phase: "idle", lastContactAt: null, lastError: null, failures: 0 },
    identity: null, // health body from the selected source
    cursor: 0,
    seen: new Set(),
    firstBatchDone: false,
    status: null,
    counts: { registered: null, acknowledged: 0, listed: null, backlog: 0 },
    files: new Map(), // path -> { seq, group }
    arrivals: [], // newest last; { id, seq, count, groups, backlog }
    arrivalSerial: 0,
    runs: new Map(), // runId -> Map(stage -> { status, attempt, durationS, errorCode, seq })
    runFirstSeq: new Map(), // runId -> seq of the first event that named it
    declaredRun: null, // the latest run id the status or result named
    currentRunId: null,
    hints: [],
    captureCheck: null,
    retake: null,
    failures: [],
    verdict: null,
    review: null,
    unknownTypes: [],
    result: { phase: "none", body: null, error: null },
    preview: { phase: "none", runId: null, cloud: null, error: null },
    log: [],
  };
}

/** A file's display group, from its packet path. Display only; never used for a decision. */
export function fileGroup(path) {
  const top = String(path).split("/")[0] ?? "";
  if (top === "keyframes" || top === "stills" || top === "truedepth") return "photo";
  if (top === "depth" || top === "confidence") return "depth";
  if (top === "mesh") return "mesh";
  return "other";
}

export function reduce(state, action) {
  if (action.type === "select") return select(state, action);
  if (action.session !== state.session) return state; // stale callback from an earlier selection
  switch (action.type) {
    case "health":
      return { ...state, identity: action.body };
    case "contact-ok":
      return {
        ...state,
        connection: { phase: "live", lastContactAt: action.at, lastError: null, failures: 0 },
      };
    case "contact-failed":
      return {
        ...state,
        connection: {
          ...state.connection,
          phase: action.offline ? "offline" : "reconnecting",
          lastError: action.error,
          failures: state.connection.failures + 1,
        },
      };
    case "gone":
      return {
        ...state,
        connection: { ...state.connection, phase: "gone", lastError: action.error },
      };
    case "stopped":
      return { ...state, connection: { ...state.connection, phase: "stopped" } };
    case "status":
      return applyStatus(state, action.body);
    case "events":
      return applyEvents(state, action.body, action.at, action.catchUp);
    case "result-loading":
      // Refreshing a result already shown keeps showing it until the new one arrives.
      return { ...state, result: { ...state.result, phase: state.result.phase === "ready" ? "ready" : "loading", error: null } };
    case "result":
      return applyResult(state, action.body);
    case "result-error":
      // A failed refresh keeps a result already shown; it is still what the server last said.
      return { ...state, result: { ...state.result, phase: state.result.phase === "ready" ? "ready" : "error", error: action.error } };
    case "preview-loading":
      return { ...state, preview: { phase: "loading", runId: action.runId, cloud: null, error: null } };
    case "preview":
      if (action.runId !== (state.result.body?.runId ?? null)) return state; // a model for another run
      // Readiness counts drawable points, not the file's declared count.
      return { ...state, preview: { phase: action.cloud.kept > 0 ? "ready" : "empty", runId: action.runId, cloud: action.cloud, error: null } };
    case "preview-error":
      return {
        ...state,
        preview: { phase: action.unsupported ? "unsupported" : "error", runId: action.runId, cloud: null, error: action.error },
      };
    default:
      return state;
  }
}

function select(state, action) {
  const next = initialState();
  next.session = state.session + 1;
  next.mode = action.mode;
  next.source = action.source;
  next.captureId = action.captureId ?? null;
  next.connection = { ...next.connection, phase: action.mode === "idle" ? "idle" : "connecting" };
  return next;
}

function applyStatus(state, body) {
  if (!isObject(body) || (body.captureId && body.captureId !== state.captureId)) return state;
  const next = {
    ...state,
    status: typeof body.status === "string" ? body.status : state.status,
    counts: {
      ...state.counts,
      registered: toCount(body.filesRegistered) ?? state.counts.registered,
    },
  };
  return typeof body.runId === "string" ? noteRun(next, body.runId) : next;
}

/**
 * How recent a run is. Runs start one after another, so a run whose first event has a higher seq
 * is newer. A run the status or result named but no event has mentioned yet ranks above all:
 * those endpoints report the latest run, and history read later must not displace it.
 */
function runRank(state, runId) {
  if (state.runFirstSeq.has(runId)) return state.runFirstSeq.get(runId);
  return runId === state.declaredRun ? Infinity : -1;
}

/**
 * Records a run id, from an event (with its seq) or from the status or result (seq null), and
 * makes the most recent known run current. When the current run changes, evidence tied to another
 * run (its verdict, result and model) is cleared, so the view never pairs one run's answer with
 * another's progress.
 */
function noteRun(state, runId, seq = null) {
  let next = state;
  if (seq == null) {
    if (state.declaredRun !== runId) next = { ...next, declaredRun: runId };
  } else if (!state.runFirstSeq.has(runId)) {
    next = { ...next, runFirstSeq: new Map(state.runFirstSeq).set(runId, seq) };
  }
  const known = new Set([...next.runFirstSeq.keys(), ...(next.declaredRun ? [next.declaredRun] : [])]);
  let current = null;
  for (const id of known) if (current == null || runRank(next, id) > runRank(next, current)) current = id;
  if (current === state.currentRunId) return next;
  next = { ...next, currentRunId: current };
  if (state.currentRunId == null) return next;
  if (next.verdict && next.verdict.runId !== current) next.verdict = null;
  if (next.retake && next.retake.runId !== current) next.retake = null;
  // A result read with no body yet (loading or failed) belonged to the previous run too.
  if (next.result.body ? next.result.body.runId !== current : next.result.phase !== "none") next.result = { phase: "none", body: null, error: null };
  if (next.preview.runId && next.preview.runId !== current) next.preview = { phase: "none", runId: null, cloud: null, error: null };
  return log(next, { seq: null, at: null, kind: "run", text: `Showing run ${current}` });
}

function applyEvents(state, body, at, catchUp) {
  if (!isObject(body)) return state;
  const events = Array.isArray(body.events) ? body.events : [];
  // Events read while catching up on history arrived before the viewer connected.
  const backlog = catchUp ?? !state.firstBatchDone;
  let next = {
    ...state,
    firstBatchDone: true,
    status: typeof body.status === "string" ? body.status : state.status,
  };
  const fresh = events
    .filter((e) => isObject(e) && Number.isInteger(e.seq) && e.seq > 0 && !state.seen.has(e.seq))
    .sort((a, b) => a.seq - b.seq);
  if (fresh.length > 0) {
    next.seen = new Set(state.seen);
    for (const event of fresh) {
      next.seen.add(event.seq);
      next = applyEvent(next, event, backlog);
    }
  }
  const maxSeq = fresh.reduce((m, e) => Math.max(m, e.seq), 0);
  const reported = Number.isInteger(body.next) ? body.next : 0;
  next.cursor = Math.max(state.cursor, reported, maxSeq);
  if (at != null) next.connection = { phase: "live", lastContactAt: at, lastError: null, failures: 0 };
  return next;
}

function applyEvent(state, event, backlog) {
  const data = isObject(event.data) ? event.data : {};
  const base = { seq: event.seq, at: typeof event.at === "string" ? event.at : null };
  if (!KNOWN_EVENTS.has(event.type)) {
    const type = String(event.type).slice(0, 40);
    const unknownTypes = state.unknownTypes.includes(type) ? state.unknownTypes : [...state.unknownTypes, type];
    return log({ ...state, unknownTypes }, { ...base, kind: "unknown", text: `Unrecognized event “${type}”` });
  }
  switch (event.type) {
    case "files_committed":
      return filesCommitted(state, data, base, backlog);
    case "stage":
      return stage(state, data, base);
    case "hint": {
      const hint = { ...base, code: str(data.code), message: str(data.message), retake: str(data.retake) };
      return log({ ...state, hints: [...state.hints, hint].slice(-6) }, { ...base, kind: "hint", text: `Server hint: ${hint.message || hint.code || "no text"}` });
    }
    case "capture_check": {
      const missing = Array.isArray(data.missing) ? data.missing.map(String) : [];
      const check = { ...base, complete: data.complete === true, missing, meterRead: str(data.meterRead) };
      const text = check.complete ? "Coverage check: nothing missing" : `Coverage check: missing ${missing.join(", ") || "unspecified views"}`;
      return log({ ...state, captureCheck: check }, { ...base, kind: "check", text });
    }
    case "retake_request": {
      const views = Array.isArray(data.viewsNeeded) ? data.viewsNeeded.map(String) : [];
      // A retake starts from a run; if it names a newer one, that run's evidence replaces the old.
      if (str(data.runId)) state = noteRun(state, data.runId, base.seq);
      const named = views.length ? `: ${views.join(", ")}` : "";
      return log({ ...state, retake: { ...base, views, runId: str(data.runId) } }, { ...base, kind: "retake", text: `Server asked for more views${named}` });
    }
    case "verdict_ready": {
      const verdict = { ...base, runId: str(data.runId), kind: str(data.kind) };
      if (verdict.runId) state = noteRun(state, verdict.runId, base.seq);
      if (verdict.runId && verdict.runId !== state.currentRunId) return log(state, { ...base, kind: "verdict", text: `Result reported for an earlier run (${verdict.runId})` });
      return log({ ...state, verdict }, { ...base, kind: "verdict", text: `Server reported a result (${verdict.kind || "kind not given"})` });
    }
    case "failed": {
      const failure = { ...base, code: str(data.code), message: str(data.message), next: str(data.next) };
      const text = `Server reported a failure: ${failure.message || failure.code || "no detail"}`;
      return log({ ...state, failures: [...state.failures, failure].slice(-6) }, { ...base, kind: "failed", text });
    }
    case "review_started":
    case "review_completed":
      return log({ ...state, review: { ...base, type: event.type } }, { ...base, kind: "review", text: event.type === "review_started" ? "A reviewer opened the capture" : "A reviewer finished the capture" });
    case "confirmation":
      return log(state, { ...base, kind: "confirmation", text: `Homeowner answered a ${str(data.fieldId) || "field"} question` });
    default:
      return state;
  }
}

function filesCommitted(state, data, base, backlog) {
  const paths = Array.isArray(data.paths) ? data.paths.filter((p) => typeof p === "string") : [];
  const files = new Map(state.files);
  const groups = { photo: 0, depth: 0, mesh: 0, other: 0 };
  let added = 0;
  for (const path of paths) {
    if (files.has(path)) continue; // the same path acknowledged twice is one file
    const group = fileGroup(path);
    files.set(path, { seq: base.seq, group });
    groups[group] += 1;
    added += 1;
  }
  const listed = toCount(data.listed) ?? state.counts.listed;
  // The backlog total is counted here, not from `arrivals`, which keeps only recent batches.
  const backlogCount = state.counts.backlog + (backlog ? added : 0);
  let next = { ...state, files, counts: { ...state.counts, acknowledged: files.size, listed, backlog: backlogCount } };
  if (added === 0) return next;
  const arrival = { id: state.arrivalSerial + 1, seq: base.seq, count: added, groups, backlog };
  next = { ...next, arrivalSerial: arrival.id, arrivals: [...state.arrivals, arrival].slice(-ARRIVAL_LIMIT) };
  return log(next, { ...base, kind: "files", text: `Server acknowledged ${added} file${added === 1 ? "" : "s"}` });
}

function stage(state, data, base) {
  const name = str(data.stage);
  const runId = str(data.runId) || state.currentRunId || "unknown-run";
  if (!name) return log(state, { ...base, kind: "unknown", text: "Stage event without a stage name" });
  state = noteRun(state, runId, base.seq);
  const runs = new Map(state.runs);
  const stages = new Map(runs.get(runId) ?? []);
  const prior = stages.get(name);
  if (prior && prior.seq > base.seq) return state;
  stages.set(name, {
    status: str(data.status) || "unknown",
    attempt: Number.isInteger(data.attempt) ? data.attempt : null,
    durationS: typeof data.durationS === "number" ? data.durationS : null,
    errorCode: str(data.errorCode),
    seq: base.seq,
  });
  runs.set(runId, stages);
  const label = STAGES.find(([id]) => id === name)?.[1] ?? name;
  return log(
    { ...state, runs },
    { ...base, kind: "stage", text: `${label}: ${str(data.status) || "unknown"}` },
  );
}

/** Statuses after which no outcome will come, so a result without one is final. */
const NO_OUTCOME_STATUSES = new Set(["failed", "expired"]);

function applyResult(state, body) {
  if (!isObject(body)) return { ...state, result: { phase: "error", body: null, error: "Result was not a JSON object" } };
  // A result for a run the view is not showing is held back; the next read will match.
  const knownRun = typeof body.runId === "string" && (state.runFirstSeq.has(body.runId) || state.declaredRun === body.runId);
  if (knownRun && state.currentRunId && body.runId !== state.currentRunId && runRank(state, body.runId) < runRank(state, state.currentRunId)) {
    return state;
  }
  if (typeof body.runId === "string") state = noteRun(state, body.runId);
  const ready = body.outcome != null || NO_OUTCOME_STATUSES.has(body.status);
  // A refreshed result that no longer offers a preview takes the earlier model with it.
  const preview = !hasPreview(body) && state.preview.runId === body.runId ? { phase: "none", runId: null, cloud: null, error: null } : state.preview;
  return { ...state, preview, result: { phase: ready ? "ready" : "pending", body, error: null } };
}

function log(state, entry) {
  return { ...state, log: [...state.log, entry].slice(-LOG_LIMIT) };
}

// ---- Selectors: derived views the renderer reads. ----

/** Connection health as the viewer shows it; `now` comes from the caller so this stays pure. */
export function connectionView(state, now, staleAfterMs = 40_000) {
  const { phase, lastContactAt, lastError } = state.connection;
  const age = lastContactAt == null ? null : Math.max(0, now - lastContactAt);
  if (phase === "live" && age != null && age > staleAfterMs) return { phase: "stale", age, lastError };
  return { phase, age, lastError };
}

/** Capture statuses after which no stage is still working. */
const SETTLED_STATUSES = new Set(["complete", "manual_review", "needs_views", "failed", "expired"]);

/**
 * Stage rows for the current run, in pipeline order, plus any stage names this viewer does not
 * know. Once the capture has settled, a stage whose last event was "running" shows as
 * "no end reported": the server never said it finished, and it is no longer working on it.
 */
export function stageRows(state) {
  const stages = state.runs.get(state.currentRunId) ?? new Map();
  const settled = SETTLED_STATUSES.has(state.status);
  const row = (id, label, value) => {
    const r = { id, label, ...(value ?? { status: "unreported" }) };
    return settled && r.status === "running" ? { ...r, status: "unended" } : r;
  };
  const rows = STAGES.map(([id, label]) => row(id, label, stages.get(id)));
  for (const [id, value] of stages) {
    if (!STAGES.some(([known]) => known === id)) rows.push(row(id, id, value));
  }
  return rows;
}

/**
 * True when the finished stages all reported near-zero durations, which is what placeholder
 * stages produce. The viewer shows this as a caution next to the stages, never as a verdict.
 */
export function looksLikePlaceholderStages(state) {
  const done = stageRows(state).filter((r) => r.status === "done");
  return done.length >= 3 && done.every((r) => r.durationS != null && r.durationS < 0.05);
}

/**
 * The views the server asked for, for the current run: from the result when it lists any,
 * otherwise from a retake request. Each has the view id and the server's prompt title, if given.
 */
export function viewsToShow(state) {
  const body = state.result.body;
  const listed = [...(Array.isArray(body?.viewsNeeded) ? body.viewsNeeded : []), ...(Array.isArray(body?.outcome?.viewsNeeded) ? body.outcome.viewsNeeded : [])];
  const seen = new Set();
  const fromResult = listed
    .filter((v) => isObject(v) && typeof v.id === "string" && !seen.has(v.id) && seen.add(v.id))
    .map((v) => ({ id: v.id, title: typeof v.prompt?.title === "string" ? v.prompt.title : null }));
  if (fromResult.length > 0) return fromResult;
  return state.retake ? state.retake.views.map((id) => ({ id, title: null })) : [];
}

/** A non-empty preview URL; an empty string means the result has no preview. */
export function hasPreview(body) {
  return typeof body?.previewUrl === "string" && body.previewUrl !== "";
}

/** Whether the events say a result exists, or that none will come, so the viewer should read it. */
export function resultExpected(state) {
  return state.verdict != null || RESULT_STATUSES.has(state.status);
}

/** Identifies what the result was read for; a new verdict or status means read it again. */
export function resultKey(state) {
  return `${state.currentRunId ?? "-"}|${state.verdict?.seq ?? "-"}|${state.status}`;
}

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function str(value) {
  return typeof value === "string" ? value : null;
}

function toCount(value) {
  return Number.isInteger(value) && value >= 0 ? value : null;
}
