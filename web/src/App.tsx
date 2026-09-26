import { useCallback, useEffect, useRef, useState } from "react";
import { ResultView, STAMP } from "./components/ResultView.tsx";
import { ScenePanel } from "./components/ScenePanel.tsx";
import { ServerSetting } from "./components/ServerSetting.tsx";
import {
  checkHealth,
  type Failure,
  type Health,
  type Placement,
  PlacementError,
  parseResult,
  requestPlacement,
} from "./lib/api.ts";
import { type SceneInput, sceneFromFile, sceneFromSample } from "./lib/scene-input.ts";
import { SAMPLES, type Sample } from "./samples/index.ts";

// "/api" is the Vite dev proxy to a local server (vite.config.ts). A deployment points
// VITE_PLACEMENT_API at its server; a reviewer can override it in the page.
const DEFAULT_SERVER = import.meta.env.VITE_PLACEMENT_API ?? "/api";
const SERVER_KEY = "placement-server";

type View =
  | { status: "empty" }
  | { status: "loading"; input: SceneInput; previous: Shown | null }
  | { status: "shown"; input: SceneInput; shown: Shown }
  /** input is null for a file refused in the browser, which there is no point resending. */
  | { status: "failed"; input: SceneInput | null; name: string; failure: Failure };

interface Shown extends Placement {
  saved: boolean;
  /** Changes for every new answer, so its entrance plays again. */
  key: number;
  /** Whether it replaced another answer, which then only re-stamps instead of rising in. */
  replacing: boolean;
}

function savedAnswer(sample: Sample): Placement {
  return { result: parseResult(JSON.parse(sample.savedResult)), plan: sample.savedPlan };
}

// Storage can be blocked (a sandboxed frame, strict privacy settings); the page still works.
function storedServer(): string {
  try {
    return localStorage.getItem(SERVER_KEY) ?? DEFAULT_SERVER;
  } catch {
    return DEFAULT_SERVER;
  }
}

function storeServer(server: string) {
  try {
    // Only an override is stored, so a new VITE_PLACEMENT_API reaches returning visitors.
    if (server === DEFAULT_SERVER) {
      localStorage.removeItem(SERVER_KEY);
    } else {
      localStorage.setItem(SERVER_KEY, server);
    }
  } catch {
    // Nothing to do: the choice lasts for this visit.
  }
}

function setSampleParam(id: string | null) {
  const url = new URL(window.location.href);
  if (id === null) {
    url.searchParams.delete("sample");
  } else {
    url.searchParams.set("sample", id);
  }
  window.history.replaceState(null, "", url);
}

function failureOf(error: unknown): Failure {
  if (error instanceof PlacementError) {
    return error.failure;
  }
  return { kind: "unexpected", message: error instanceof Error ? error.message : String(error) };
}

const FAILURE_TITLE: Record<Failure["kind"], string> = {
  unreachable: "Can't reach the placement server",
  refused: "The server refused this scene",
  unexpected: "That didn't work",
};

export function App() {
  const [server, setServer] = useState(storedServer);
  const [healthCheck, setHealthCheck] = useState(0);
  const [health, setHealth] = useState<Health | null>(null);
  const [view, setView] = useState<View>({ status: "empty" });
  const serverRef = useRef(server);
  const inFlight = useRef<AbortController | null>(null);
  const answers = useRef(0);
  const sheet = useRef<HTMLElement>(null);

  // biome-ignore lint/correctness/useExhaustiveDependencies: healthCheck re-runs the same check.
  useEffect(() => {
    const controller = new AbortController();
    setHealth(null);
    checkHealth(server, controller.signal).then((next) => {
      if (!controller.signal.aborted) {
        setHealth(next);
      }
    });
    return () => controller.abort();
  }, [server, healthCheck]);

  const solve = useCallback(async (input: SceneInput) => {
    inFlight.current?.abort();
    const controller = new AbortController();
    inFlight.current = controller;
    setView((current) => ({
      status: "loading",
      input,
      previous: current.status === "shown" ? current.shown : null,
    }));
    try {
      const placement = await requestPlacement(serverRef.current, input, controller.signal);
      answers.current += 1;
      setView((current) => ({
        status: "shown",
        input,
        shown: {
          ...placement,
          saved: false,
          key: answers.current,
          replacing: current.status === "loading" && current.previous !== null,
        },
      }));
      // The answer proves the server is up and names its rules.
      setHealth({ ok: true, policy: placement.result.policy.id ?? "none" });
    } catch (error) {
      if (controller.signal.aborted) {
        return;
      }
      const failure = failureOf(error);
      setView({ status: "failed", input, name: input.name, failure });
      if (failure.kind === "unreachable") {
        setHealth({ ok: false });
      }
    }
  }, []);

  function pickSample(sample: Sample) {
    // The address names the sample, so a link opens the same answer.
    setSampleParam(sample.id);
    solve(sceneFromSample(sample.id, sample.title, sample.scene));
  }

  async function pickFile(file: File) {
    setSampleParam(null);
    try {
      await solve(await sceneFromFile(file));
    } catch (error) {
      inFlight.current?.abort();
      setView({ status: "failed", input: null, name: file.name, failure: failureOf(error) });
    }
  }

  // biome-ignore lint/correctness/useExhaustiveDependencies: opens the linked sample once, on load.
  useEffect(() => {
    const linked = SAMPLES.find(
      (s) => s.id === new URLSearchParams(window.location.search).get("sample"),
    );
    if (linked) {
      pickSample(linked);
    }
  }, []);

  function showSaved(sample: Sample, input: SceneInput) {
    answers.current += 1;
    setView({
      status: "shown",
      input,
      shown: { ...savedAnswer(sample), saved: true, key: answers.current, replacing: false },
    });
  }

  function changeServer(next: string) {
    inFlight.current?.abort();
    serverRef.current = next;
    storeServer(next);
    setServer(next);
    setHealthCheck((n) => n + 1);
    // A scene that failed is usually why the server was changed: ask the new one.
    if (view.status === "failed" && view.input) {
      solve(view.input);
    } else if (view.status === "loading") {
      setView(
        view.previous
          ? { status: "shown", input: view.input, shown: view.previous }
          : { status: "empty" },
      );
    }
  }

  // On a phone the scene list sits above the sheet, so bring a new answer into view.
  useEffect(() => {
    if (view.status !== "shown" && view.status !== "failed") {
      return;
    }
    const top = sheet.current?.getBoundingClientRect().top ?? 0;
    if (top > window.innerHeight * 0.6) {
      sheet.current?.scrollIntoView({ block: "start" });
    }
  }, [view.status]);

  const input = view.status === "empty" ? null : view.input;
  const failed = view.status === "failed" ? view : null;
  const retryInput = failed?.input ?? null;
  const fileName =
    view.status === "failed" && view.input === null
      ? view.name
      : input && input.sampleId === null
        ? input.name
        : null;
  const shown =
    view.status === "shown" ? view.shown : view.status === "loading" ? view.previous : null;
  const announcement =
    view.status === "loading"
      ? `Checking ${view.input.name}…`
      : view.status === "shown"
        ? `${STAMP[view.shown.result.decision]}: ${view.shown.result.summary}`
        : view.status === "failed"
          ? FAILURE_TITLE[view.failure.kind]
          : "";

  return (
    <div className="page">
      <header className="bar">
        <h1 className="brand">
          Placement review <span className="brand-sub">House Scan</span>
        </h1>
        <ServerSetting server={server} health={health} onChange={changeServer} />
      </header>
      <p className="visually-hidden" role="status">
        {announcement}
      </p>
      <main className="layout">
        <aside className="aside">
          <ScenePanel
            activeSampleId={input?.sampleId ?? null}
            fileName={fileName}
            onSample={pickSample}
            onFile={pickFile}
          />
        </aside>
        <section ref={sheet} className="sheet" aria-label="Answer">
          {view.status === "loading" && <div className="progress" aria-hidden="true" />}
          {view.status === "empty" && <EmptyView />}
          {failed && (
            <FailureView
              failure={failed.failure}
              sample={SAMPLES.find((s) => s.id === retryInput?.sampleId) ?? null}
              onRetry={retryInput ? () => solve(retryInput) : null}
              onSaved={(sample) => retryInput && showSaved(sample, retryInput)}
            />
          )}
          {view.status === "loading" && !shown && (
            <p className="waiting">Asking the placement server…</p>
          )}
          {shown && (
            <div className="answer" data-stale={view.status === "loading"}>
              <ResultView
                key={shown.key}
                result={shown.result}
                plan={shown.plan}
                saved={shown.saved}
                entrance={shown.replacing ? "stamp" : "full"}
              />
            </div>
          )}
        </section>
      </main>
    </div>
  );
}

function EmptyView() {
  return (
    <div className="empty">
      <h2>Where does the battery go?</h2>
      <p>
        Pick a sample or drop a scan. The placement server answers with a spot, the cable run, a
        site plan and the reason behind every check.
      </p>
    </div>
  );
}

interface FailureProps {
  failure: Failure;
  sample: Sample | null;
  /** Null when resending cannot help (a file the page itself refused). */
  onRetry: (() => void) | null;
  onSaved: (sample: Sample) => void;
}

function FailureView({ failure, sample, onRetry, onSaved }: FailureProps) {
  return (
    <div className="failure">
      <h2>{FAILURE_TITLE[failure.kind]}</h2>
      {failure.kind === "unreachable" && (
        <>
          <p>
            Nothing answered at <code className="address">{failure.server}</code>. Start the server
            from <code>server/</code> with <code>uv run uvicorn api:app</code>, or point this page
            at another one with Change above.
          </p>
          <p className="detail">{failure.detail}</p>
        </>
      )}
      {failure.kind === "refused" && (
        <>
          <p>{failure.message}</p>
          <p className="detail">
            {failure.code}
            {failure.path ? ` at ${failure.path}` : ""}
          </p>
        </>
      )}
      {failure.kind === "unexpected" && <p>{failure.message}</p>}
      <div className="actions">
        {onRetry && (
          <button type="button" className="button" onClick={onRetry}>
            Try again
          </button>
        )}
        {sample && failure.kind === "unreachable" && (
          <button type="button" className="button quiet" onClick={() => onSaved(sample)}>
            Show the saved answer
          </button>
        )}
      </div>
    </div>
  );
}
