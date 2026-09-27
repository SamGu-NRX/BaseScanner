// Self-authored synthetic captures. The browser's illustrative replay and the loopback synthetic
// API both play these timelines, so the two paths exercise the same event shapes. Nothing here
// comes from a real capture, and the copy is ours, not the server's catalogue text.

export const SCENARIOS = {
  complete: { label: "Full run to a result" },
  failed: { label: "Packet rejected after upload" },
  dropout: { label: "Connection drops mid-run" },
};

/** The outage window, in ms from the start, for the `dropout` scenario. */
export const DROPOUT = { from: 11_000, to: 19_000 };

const RUN_ID = "run_synthetic";

/**
 * The scenario as a list of steps sorted by `t` (ms from start). A step sets the capture status,
 * the registered-file count, or appends one event.
 */
export function timeline(name) {
  const steps = [];
  const at = (t, step) => steps.push({ t, ...step });
  at(0, { status: "uploading", registered: 0 });

  // Uploads: four meter stills, then keyframes each followed by depth and confidence.
  let registered = 0;
  const stills = ["stills/s01.jpg", "stills/s02.jpg", "stills/s03.jpg", "stills/s04.jpg"];
  registered += stills.length;
  at(300, { registered });
  at(900, { event: { type: "files_committed", data: { paths: stills.slice(0, 2), committed: 2 } } });
  at(1_700, { event: { type: "files_committed", data: { paths: stills.slice(2), committed: 2 } } });
  let t = 2_300;
  for (let batch = 0; batch < 8; batch += 1) {
    const paths = [];
    for (let k = 0; k < 4; k += 1) {
      const n = String(batch * 4 + k).padStart(5, "0");
      paths.push(`keyframes/k${n}.jpg`, `depth/k${n}.bin`, `confidence/k${n}.bin`);
    }
    registered += paths.length;
    at(t - 400, { registered });
    at(t, { event: { type: "files_committed", data: { paths, committed: paths.length } } });
    if (batch === 2) {
      at(t + 250, {
        event: {
          type: "hint",
          data: { code: "synthetic_hold_steady", message: "Synthetic hint: slow down near the meter so the photos stay sharp." },
        },
      });
    }
    t += 900;
  }
  const tail = ["mesh/mesh.bin", "streams/poses.bin"];
  registered += tail.length;
  at(t - 300, { registered });
  at(t, { event: { type: "files_committed", data: { paths: tail, committed: tail.length, listed: registered } } });
  at(t + 500, { event: { type: "capture_check", data: { complete: true, missing: [], meterRead: "ok" } } });
  at(t + 900, { status: "processing" });

  if (name === "failed") {
    at(t + 1_300, { event: { type: "stage", data: { stage: "validate", status: "running", attempt: 1, runId: RUN_ID } } });
    at(t + 3_200, {
      event: {
        type: "failed",
        data: { code: "synthetic_depth_size", message: "Synthetic failure: a depth file does not match its keyframe size.", next: "none" },
      },
    });
    at(t + 3_200, { status: "failed" });
    return steps.sort((a, b) => a.t - b.t);
  }

  // Stage durations are ours, chosen so the illustration reads; they are not measurements.
  const durations = { validate: 900, poses: 2_600, objects: 1_400, reads: 1_100, scale: 900, dense: 3_200, coverage: 1_300, scene: 1_700, objects_3d: 1_000, criteria: 1_100, result: 600 };
  let s = t + 1_300;
  const stage = (name, status, extra = {}) => ({ event: { type: "stage", data: { stage: name, status, attempt: 1, runId: RUN_ID, ...extra } } });
  // objects and reads run beside poses; everything else waits on the previous stage.
  at(s, stage("validate", "running"));
  s += durations.validate;
  at(s, stage("validate", "done", { durationS: durations.validate / 1000 }));
  at(s + 50, stage("poses", "running"));
  at(s + 120, stage("objects", "running"));
  at(s + 180, stage("reads", "running"));
  at(s + 180 + durations.reads, stage("reads", "done", { durationS: durations.reads / 1000 }));
  at(s + 120 + durations.objects, stage("objects", "done", { durationS: durations.objects / 1000 }));
  s += 50 + durations.poses;
  at(s, stage("poses", "done", { durationS: durations.poses / 1000 }));
  for (const name of ["scale", "dense", "coverage", "scene", "objects_3d", "criteria", "result"]) {
    s += 80;
    at(s, stage(name, "running"));
    s += durations[name];
    at(s, stage(name, "done", { durationS: durations[name] / 1000 }));
  }
  at(s + 100, { event: { type: "verdict_ready", data: { runId: RUN_ID, kind: "eligible" } } });
  at(s + 100, { status: "complete" });
  return steps.sort((a, b) => a.t - b.t);
}

/** The result body the synthetic sources return once the scenario reaches a result. */
export function resultBody(name, status) {
  if (name === "failed") {
    return { runId: RUN_ID, status, viewsNeeded: [], memberActions: [], outcome: null };
  }
  if (status !== "complete") return { runId: RUN_ID, status, viewsNeeded: [], memberActions: [], outcome: null };
  return {
    runId: RUN_ID,
    status: "complete",
    viewsNeeded: [],
    memberActions: [],
    outcome: {
      kind: "eligible",
      profile: "C",
      message: "Synthetic example: the battery fits on the wall to the left of the meter.",
      viewsNeeded: [],
      reasons: [],
      recommendedPlacement: {
        wallId: "w1",
        startSM: 0.3,
        footprintM: { w: 0.79, h: 1.0, d: 0.56 },
        boxSceneM: { centerM: [0.7, 0.5, 0.28], sizeM: [0.79, 1.0, 0.56], yawDeg: 0 },
        confidence: 0.8,
        profile: "C",
      },
    },
    // No thresholds: clearance limits live in the server's sourced rules files, and an
    // illustration must not state its own.
    criteria: [
      { id: "synthetic_gas_clearance", outcome: "pass", measuredFt: 4.1, coverage: "observed" },
      { id: "synthetic_window_clearance", outcome: "pass", measuredFt: 2.2, coverage: "observed" },
      { id: "synthetic_ground_slope", outcome: "unsure", coverage: "partial" },
    ],
    previewUrl: "synthetic",
  };
}

/** Deterministic pseudo-random numbers, so the synthetic wall looks the same every run. */
function rng(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let x = a;
    x = Math.imul(x ^ (x >>> 15), x | 1);
    x ^= x + Math.imul(x ^ (x >>> 7), x | 61);
    return ((x ^ (x >>> 14)) >>> 0) / 4294967296;
  };
}

/**
 * A synthetic wall scene as a point list: a siding wall with a window opening, a meter box, the
 * ground in front, and a shrub. Points behind the shrub carry generated=1, the way a server marks
 * filled-in geometry. Units are metres, +y up, the wall on z=0 facing +z.
 */
export function syntheticCloud() {
  const random = rng(20260927);
  const points = [];
  const push = (x, y, z, generated = 0) => points.push([x, y, z, generated]);
  const behindShrub = (x, y) => (x - 3.2) ** 2 / 0.36 + y ** 2 / 0.64 < 1;
  for (let i = 0; i < 16_000; i += 1) {
    const x = random() * 4.2;
    const y = random() * 2.7;
    if (x > 2.3 && x < 3.3 && y > 1.0 && y < 2.1) continue; // window opening
    const course = Math.floor(y / 0.18);
    const z = 0.004 * Math.sin(course * 1.7) + (y % 0.18 < 0.012 ? -0.006 : 0);
    push(x, y, z, behindShrub(x, y) ? 1 : 0);
  }
  for (let i = 0; i < 2_600; i += 1) {
    // meter box: front face plus sides, 0.35 x 0.5 x 0.18 at x=1.5..1.85, y=1.2..1.7
    const u = random();
    const v = random();
    const face = random();
    if (face < 0.6) push(1.5 + u * 0.35, 1.2 + v * 0.5, 0.18);
    else if (face < 0.8) push(1.5 + (face < 0.7 ? 0 : 0.35), 1.2 + v * 0.5, u * 0.18);
    else push(1.5 + u * 0.35, 1.2 + (face < 0.9 ? 0 : 0.5), v * 0.18);
  }
  for (let i = 0; i < 1_200; i += 1) {
    const a = random() * Math.PI * 2;
    const r = Math.sqrt(random()) * 0.11;
    push(1.675 + Math.cos(a) * r, 1.5 + Math.sin(a) * r, 0.19); // meter glass
  }
  for (let i = 0; i < 7_000; i += 1) {
    const x = random() * 4.2;
    const z = random() * 1.6;
    push(x, 0.01 * Math.sin(x * 3) + (random() - 0.5) * 0.01, z);
  }
  for (let i = 0; i < 3_000; i += 1) {
    const theta = random() * Math.PI * 2;
    const phi = Math.acos(2 * random() - 1);
    const r = 0.45 + (random() - 0.5) * 0.12;
    const y = 0.45 + r * Math.cos(phi) * 0.9;
    if (y < 0) continue;
    push(3.2 + r * Math.sin(phi) * Math.cos(theta), y, 0.5 + r * Math.sin(phi) * Math.sin(theta) * 0.8);
  }
  return points;
}

/** Encodes points as a binary little-endian PLY with float x, y, z and uchar generated. */
export function encodePly(points) {
  const header = `ply\nformat binary_little_endian 1.0\ncomment synthetic viewer fixture\nelement vertex ${points.length}\nproperty float x\nproperty float y\nproperty float z\nproperty uchar generated\nend_header\n`;
  const head = new TextEncoder().encode(header);
  const out = new Uint8Array(head.length + points.length * 13);
  out.set(head);
  const view = new DataView(out.buffer);
  let at = head.length;
  for (const [x, y, z, g] of points) {
    view.setFloat32(at, x, true);
    view.setFloat32(at + 4, y, true);
    view.setFloat32(at + 8, z, true);
    view.setUint8(at + 12, g);
    at += 13;
  }
  return out;
}
