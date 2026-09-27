// The survey line between phone and server. When the server acknowledges files, a few marks
// travel the line and the counter at its end updates as they land. Travel is short and bounded;
// with motion off the counter updates at once and nothing moves.

const TRAVEL_MS = 1100;
const STAGGER_MS = 70;
const MAX_MARKS_PER_ARRIVAL = 6;
const MAX_IN_FLIGHT = 18;

export class Conduit {
  /**
   * @param {HTMLElement} box   container the line spans
   * @param {SVGPathElement[]} paths  base line and tick overlay, drawn with the same geometry
   * @param {HTMLElement} layer container for travelling marks
   */
  constructor(box, paths, layer) {
    this.box = box;
    this.paths = paths;
    this.layer = layer;
    this.samples = [];
    this.inFlight = 0;
    new ResizeObserver(() => this.layout()).observe(box);
  }

  layout() {
    const { width: w, height: h } = this.box.getBoundingClientRect();
    if (w < 2 || h < 2) return;
    const vertical = h > w * 1.2;
    // A gentle S from the phone's screen height down toward the server's first stages.
    const d = vertical
      ? `M ${w / 2} 6 C ${w / 2 + w * 0.4} ${h * 0.35}, ${w / 2 - w * 0.4} ${h * 0.65}, ${w / 2} ${h - 6}`
      : `M 6 ${h * 0.45} C ${w * 0.45} ${h * 0.45}, ${w * 0.55} ${h * 0.8}, ${w - 6} ${h * 0.8}`;
    for (const p of this.paths) p.setAttribute("d", d);
    const path = this.paths[0];
    const length = path.getTotalLength();
    this.samples = Array.from({ length: 25 }, (_, i) => path.getPointAtLength((length * i) / 24));
    const svg = path.ownerSVGElement;
    for (const [id, pt] of [["port-phone", this.samples[0]], ["port-server", this.samples.at(-1)]]) {
      const port = svg.querySelector(`#${id}`);
      port?.setAttribute("cx", String(pt.x));
      port?.setAttribute("cy", String(pt.y));
    }
  }

  /**
   * Sends marks for one acknowledged batch. Resolves when the last mark lands (at once when
   * motion is off, the batch predates the connection, or too many marks are already moving).
   */
  send(arrival, { motion }) {
    const groups = Object.entries(arrival.groups).flatMap(([group, n]) => Array(n).fill(group));
    const marks = Math.min(groups.length, MAX_MARKS_PER_ARRIVAL, Math.max(0, MAX_IN_FLIGHT - this.inFlight));
    if (!motion || arrival.backlog || marks === 0 || this.samples.length === 0) return Promise.resolve();
    const step = groups.length / marks;
    const flights = [];
    for (let i = 0; i < marks; i += 1) {
      const chip = document.createElement("span");
      chip.className = "chip";
      chip.dataset.group = groups[Math.floor(i * step)];
      this.layer.append(chip);
      this.inFlight += 1;
      const frames = this.samples.map((pt, k) => ({
        transform: `translate(${pt.x}px, ${pt.y}px)`,
        opacity: k === 0 ? 0 : k === this.samples.length - 1 ? 0 : 1,
        offset: k / (this.samples.length - 1),
      }));
      const anim = chip.animate(frames, { duration: TRAVEL_MS, delay: i * STAGGER_MS, easing: "cubic-bezier(0.77, 0, 0.175, 1)", fill: "backwards" });
      flights.push(
        anim.finished.catch(() => {}).finally(() => {
          chip.remove();
          this.inFlight -= 1;
        }),
      );
    }
    return Promise.all(flights).then(() => {});
  }

  /** Removes marks in flight, for a capture switch. */
  clear() {
    for (const chip of this.layer.querySelectorAll(".chip")) {
      for (const a of chip.getAnimations()) a.cancel();
    }
  }
}
