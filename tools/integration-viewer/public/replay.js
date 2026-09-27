// Plays a synthetic scenario through the same reducer actions the live path uses. It never touches
// the network. The `dropout` scenario withholds events during its outage window and then delivers
// them in one batch, which is what a reconnecting long-poll sees.

import { DROPOUT, encodePly, resultBody, syntheticCloud, timeline } from "./scenario.js";
import { parsePly } from "./ply.js";

export const REPLAY_CAPTURE_ID = "cap_ILLUSTRATIVE";

let cachedCloud = null;

export class ReplayPlayer {
  /** @param {{ scenario: string, session: number, dispatch: (a: object) => void, onEnd?: () => void }} options */
  constructor({ scenario, session, dispatch, onEnd = () => {} }) {
    this.scenario = scenario;
    this.session = session;
    this.dispatch = (action) => dispatch({ ...action, session });
    this.onEnd = onEnd;
    this.steps = timeline(scenario === "dropout" ? "complete" : scenario);
    let seq = 0;
    for (const step of this.steps) if (step.event) step.seq = ++seq;
    this.index = 0;
    this.elapsed = 0;
    this.startedAt = null;
    this.timer = 0;
    this.held = [];
    this.status = "uploading";
    this.registered = 0;
    this.outage = false;
    this.ended = false;
    this.stopped = false;
  }

  get playing() {
    return this.startedAt != null;
  }

  play() {
    if (this.playing || this.ended) return;
    this.startedAt = performance.now() - this.elapsed;
    this.dispatch({ type: "health", body: { status: "ok", storage: "none", state: "replay", version: "illustrative-replay" } });
    // An empty first batch, like the live catch-up read: later events count as seen arriving.
    if (this.index === 0) this.dispatch({ type: "events", body: { status: this.status, next: 0, events: [] }, at: Date.now() });
    this.tick();
  }

  pause() {
    if (!this.playing) return;
    this.elapsed = performance.now() - this.startedAt;
    this.startedAt = null;
    clearTimeout(this.timer);
  }

  stop() {
    this.pause();
    clearTimeout(this.timer);
    this.ended = true;
    this.stopped = true;
  }

  tick() {
    if (!this.playing) return;
    const now = performance.now() - this.startedAt;
    const batch = [];
    while (this.index < this.steps.length && this.steps[this.index].t <= now) {
      const step = this.steps[this.index++];
      if (step.status) this.status = step.status;
      if (step.registered != null) this.registered = step.registered;
      if (step.event) {
        batch.push({ seq: step.seq, type: step.event.type, at: new Date(Date.now() - (now - step.t)).toISOString(), data: step.event.data });
      }
      if (step.status || step.registered != null) {
        this.dispatch({ type: "status", body: { captureId: REPLAY_CAPTURE_ID, status: this.status, filesRegistered: this.registered } });
      }
    }

    const inOutage = this.scenario === "dropout" && now >= DROPOUT.from && now < DROPOUT.to;
    if (inOutage) {
      if (!this.outage) this.dispatch({ type: "contact-failed", error: "illustrative outage", offline: false });
      this.outage = true;
      this.held.push(...batch);
    } else {
      const events = this.outage ? [...this.held, ...batch] : batch;
      this.outage = false;
      this.held = [];
      if (events.length > 0 || this.index === 0) {
        this.dispatch({ type: "events", body: { status: this.status, next: events.at(-1)?.seq ?? 0, events }, at: Date.now() });
      } else {
        this.dispatch({ type: "contact-ok", at: Date.now() });
      }
    }

    if (this.index >= this.steps.length && !this.outage) {
      this.finish();
      return;
    }
    const nextAt = this.index < this.steps.length ? this.steps[this.index].t : DROPOUT.to;
    const until = inOutage ? Math.min(nextAt, DROPOUT.to) : nextAt;
    this.timer = setTimeout(() => this.tick(), Math.max(16, until - now));
  }

  finish() {
    this.ended = true;
    this.startedAt = null;
    const body = resultBody(this.scenario === "dropout" ? "complete" : this.scenario, this.status);
    this.timer = setTimeout(() => {
      if (this.stopped) return;
      this.dispatch({ type: "result-loading" });
      this.dispatch({ type: "result", body });
      if (!body.previewUrl) {
        this.onEnd();
        return;
      }
      this.dispatch({ type: "preview-loading", runId: body.runId });
      this.timer = setTimeout(() => {
        if (this.stopped) return;
        // Encode and parse, so replay exercises the same PLY path as a live preview.
        cachedCloud ??= parsePly(encodePly(syntheticCloud()).buffer);
        this.dispatch({ type: "preview", runId: body.runId, cloud: cachedCloud });
        this.onEnd();
      }, 500);
    }, 350);
  }
}
