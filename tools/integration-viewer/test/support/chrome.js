// Starts headless Chrome and speaks just enough of the DevTools protocol for the browser test.
// Set CHROME_PATH to use a browser other than the macOS default install.

import { spawn } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const DEFAULT_PATHS = ["/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", "/usr/bin/google-chrome", "/usr/bin/chromium"];

export function findChrome() {
  return [process.env.CHROME_PATH, ...DEFAULT_PATHS].find((p) => p && existsSync(p)) ?? null;
}

export async function launchChrome(path) {
  const profile = mkdtempSync(join(tmpdir(), "viewer-chrome-"));
  const child = spawn(path, ["--headless=new", "--remote-debugging-port=0", `--user-data-dir=${profile}`, "--no-first-run", "--hide-scrollbars", "about:blank"], { stdio: "ignore" });
  const portFile = join(profile, "DevToolsActivePort");
  let port = null;
  for (let i = 0; i < 100 && port == null; i += 1) {
    if (existsSync(portFile)) port = Number(readFileSync(portFile, "utf8").split("\n")[0]);
    else await new Promise((r) => setTimeout(r, 100));
  }
  if (!port) throw new Error("Chrome did not open a DevTools port");
  const pages = await (await fetch(`http://127.0.0.1:${port}/json`)).json();
  const ws = new WebSocket(pages.find((p) => p.type === "page").webSocketDebuggerUrl);
  await new Promise((resolve, reject) => {
    ws.addEventListener("open", resolve, { once: true });
    ws.addEventListener("error", reject, { once: true });
  });
  let id = 0;
  const pending = new Map();
  ws.addEventListener("message", (m) => {
    const msg = JSON.parse(m.data);
    if (msg.id && pending.has(msg.id)) {
      pending.get(msg.id)(msg);
      pending.delete(msg.id);
    }
  });
  const send = (method, params = {}) =>
    new Promise((resolve, reject) => {
      const i = ++id;
      pending.set(i, (msg) => (msg.error ? reject(new Error(`${method}: ${msg.error.message}`)) : resolve(msg.result)));
      ws.send(JSON.stringify({ id: i, method, params }));
    });
  return {
    send,
    async evaluate(expression) {
      const r = await send("Runtime.evaluate", { expression, returnByValue: true, awaitPromise: true });
      if (r.exceptionDetails) throw new Error(`page threw: ${r.exceptionDetails.exception?.description ?? r.exceptionDetails.text}`);
      return r.result.value;
    },
    async close() {
      ws.close();
      const exited = new Promise((r) => child.once("exit", r));
      child.kill();
      await Promise.race([exited, new Promise((r) => setTimeout(r, 5000))]);
      // Chrome can still be flushing its profile for a moment after exit.
      rmSync(profile, { recursive: true, force: true, maxRetries: 10, retryDelay: 200 });
    },
  };
}
