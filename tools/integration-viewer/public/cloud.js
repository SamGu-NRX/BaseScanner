// Draws a parsed point cloud on a canvas with a slow side-to-side sway, so a mostly flat wall
// still reads as 3D. The sway runs only while motion is on, the tab is visible and the canvas is on
// screen; otherwise the view is a still frame. Arrow keys and dragging turn it by hand.

const SWAY_PERIOD_MS = 16_000;
const SWAY_RAD = 0.38;
const REVEAL_MS = 900;
// The sway is slow, so 30 frames a second looks the same as 60 and halves the drawing work.
const FRAME_MS = 1000 / 30;

export class CloudView {
  /** @param {HTMLCanvasElement} canvas */
  constructor(canvas) {
    this.canvas = canvas;
    this.ctx = canvas.getContext("2d");
    this.source = null;
    this.cloud = null;
    this.motion = true;
    this.visible = true;
    this.yaw = -0.35;
    this.pitch = -0.2;
    this.swayStart = performance.now();
    this.swayPhase = 0;
    this.revealStart = 0;
    this.raf = 0;
    this.colors = null;

    new ResizeObserver(() => this.resize()).observe(canvas);
    new IntersectionObserver(([entry]) => {
      this.visible = entry.isIntersecting;
      this.kick();
    }).observe(canvas);
    document.addEventListener("visibilitychange", () => this.kick());
    matchMedia("(prefers-color-scheme: dark)").addEventListener("change", () => {
      this.colors = null;
      this.draw();
    });

    canvas.addEventListener("keydown", (e) => {
      const turn = { ArrowLeft: [-0.12, 0], ArrowRight: [0.12, 0], ArrowUp: [0, -0.08], ArrowDown: [0, 0.08] }[e.key];
      if (!turn) return;
      e.preventDefault();
      this.turn(turn[0], turn[1]);
    });
    let drag = null;
    canvas.addEventListener("pointerdown", (e) => {
      drag = { x: e.clientX, y: e.clientY };
      canvas.setPointerCapture(e.pointerId);
    });
    canvas.addEventListener("pointermove", (e) => {
      if (!drag) return;
      this.turn((e.clientX - drag.x) * 0.008, (e.clientY - drag.y) * 0.006);
      drag = { x: e.clientX, y: e.clientY };
    });
    const end = () => { drag = null; };
    canvas.addEventListener("pointerup", end);
    canvas.addEventListener("pointercancel", end);
  }

  /** @param {{ positions: Float32Array, generated: Uint8Array | null, kept: number, bounds: any } | null} cloud */
  setCloud(cloud, { reveal = true } = {}) {
    if (cloud === this.source) return;
    this.source = cloud;
    this.cloud = cloud && cloud.kept > 0 ? prepare(cloud) : null;
    this.revealStart = reveal && this.motion ? performance.now() : -Infinity;
    this.resize();
    this.kick();
  }

  setMotion(on) {
    if (on === this.motion) return;
    if (on) this.swayStart = performance.now() - this.swayPhase * SWAY_PERIOD_MS;
    else {
      this.swayPhase = this.phase(performance.now());
      this.revealStart = -Infinity; // show the whole model at once instead of finishing the reveal
    }
    this.motion = on;
    this.kick();
  }

  turn(dYaw, dPitch) {
    this.yaw += dYaw;
    this.pitch = Math.max(-1.2, Math.min(0.6, this.pitch + dPitch));
    this.draw();
  }

  phase(now) {
    return ((now - this.swayStart) / SWAY_PERIOD_MS) % 1;
  }

  resize() {
    const rect = this.canvas.getBoundingClientRect();
    const dpr = Math.min(1.5, window.devicePixelRatio || 1);
    const w = Math.max(1, Math.round(rect.width * dpr));
    const h = Math.max(1, Math.round(rect.height * dpr));
    if (this.canvas.width !== w || this.canvas.height !== h) {
      this.canvas.width = w;
      this.canvas.height = h;
      this.image = null;
    }
    this.draw();
  }

  kick() {
    const animating = this.cloud && this.visible && !document.hidden && (this.motion || performance.now() - this.revealStart < REVEAL_MS);
    if (animating && !this.raf) {
      let last = 0;
      const loop = (t) => {
        if (t - last >= FRAME_MS - 2) {
          last = t;
          this.draw();
        }
        const stillAnimating = this.cloud && this.visible && !document.hidden && (this.motion || performance.now() - this.revealStart < REVEAL_MS);
        this.raf = stillAnimating ? requestAnimationFrame(loop) : 0;
      };
      this.raf = requestAnimationFrame(loop);
    } else if (!animating) {
      if (this.raf) cancelAnimationFrame(this.raf);
      this.raf = 0;
      this.draw();
    }
  }

  draw() {
    const { canvas, ctx, cloud } = this;
    const w = canvas.width;
    const h = canvas.height;
    if (!cloud || w < 2 || h < 2) {
      ctx.clearRect(0, 0, w, h);
      return;
    }
    this.colors ??= readColors(canvas);
    if (!this.image || this.image.width !== w || this.image.height !== h) this.image = ctx.createImageData(w, h);
    const data = this.image.data;
    data.fill(0);

    const now = performance.now();
    const phase = this.motion ? this.phase(now) : this.swayPhase;
    const yaw = this.yaw + Math.sin(phase * Math.PI * 2) * SWAY_RAD;
    const reveal = Math.min(1, (now - this.revealStart) / REVEAL_MS);
    const cy = Math.cos(yaw), sy = Math.sin(yaw), cp = Math.cos(this.pitch), sp = Math.sin(this.pitch);
    const scale = (Math.min(w, h * 1.3) * 0.82) / cloud.radius / 2;
    const dist = cloud.radius * 4.5;
    const dot = Math.max(1, Math.round(Math.min(w, h) / 380));
    const { seen, gen } = this.colors;
    const { xyz, flags, heights, n } = cloud;

    for (let i = 0; i < n; i += 1) {
      const hNorm = heights[i];
      if (hNorm > reveal * 1.15) continue;
      const x = xyz[i * 3], y = xyz[i * 3 + 1], z = xyz[i * 3 + 2];
      const x1 = cy * x + sy * z;
      const z1 = -sy * x + cy * z;
      const y2 = cp * y - sp * z1;
      const z2 = sp * y + cp * z1;
      const persp = dist / (dist - z2);
      const px = Math.round(w / 2 + x1 * scale * persp);
      const py = Math.round(h / 2 - y2 * scale * persp);
      if (px < 0 || py < 0 || px >= w - dot || py >= h - dot) continue;
      const c = flags && flags[i] ? gen : seen;
      const depthShade = Math.max(0.35, Math.min(1, 0.7 + z2 / (cloud.radius * 2)));
      const fade = reveal < 1 ? Math.max(0, Math.min(1, (reveal * 1.15 - hNorm) * 6)) : 1;
      const alpha = Math.round(255 * c[3] * depthShade * fade);
      for (let dy = 0; dy < dot; dy += 1) {
        let o = ((py + dy) * w + px) * 4;
        for (let dx = 0; dx < dot; dx += 1, o += 4) {
          if (data[o + 3] >= alpha) continue;
          data[o] = c[0]; data[o + 1] = c[1]; data[o + 2] = c[2]; data[o + 3] = alpha;
        }
      }
    }
    ctx.putImageData(this.image, 0, 0);
  }
}

/** Centres the cloud and precomputes normalized heights for the bottom-up reveal. */
function prepare(cloud) {
  const n = cloud.kept;
  const { min, max } = cloud.bounds;
  const center = [0, 1, 2].map((a) => (min[a] + max[a]) / 2);
  const xyz = new Float32Array(n * 3);
  const heights = new Float32Array(n);
  const flags = cloud.generated ? new Uint8Array(n) : null;
  const span = max[1] - min[1] || 1;
  let radius = 0;
  let kept = 0;
  for (let i = 0; i < n; i += 1) {
    const x = cloud.positions[i * 3] - center[0];
    const y = cloud.positions[i * 3 + 1] - center[1];
    const z = cloud.positions[i * 3 + 2] - center[2];
    if (!Number.isFinite(x) || !Number.isFinite(y) || !Number.isFinite(z)) continue;
    xyz[kept * 3] = x; xyz[kept * 3 + 1] = y; xyz[kept * 3 + 2] = z;
    heights[kept] = (cloud.positions[i * 3 + 1] - min[1]) / span;
    if (flags) flags[kept] = cloud.generated[i];
    radius = Math.max(radius, Math.hypot(x, y, z));
    kept += 1;
  }
  return { xyz, heights, flags, n: kept, radius: radius || 1 };
}

function readColors(canvas) {
  const style = getComputedStyle(canvas);
  const probe = (name, alpha) => [...parseColor(style.getPropertyValue(name)), alpha];
  return { seen: probe("--ink", 0.85), gen: probe("--unsure", 0.9) };
}

function parseColor(value) {
  const hex = value.trim().replace("#", "");
  if (/^[0-9a-f]{6}$/i.test(hex)) return [0, 2, 4].map((i) => parseInt(hex.slice(i, i + 2), 16));
  return [128, 128, 128];
}
