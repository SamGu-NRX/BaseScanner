import { useCallback, useEffect, useRef, useState } from "react";
import { ResultView } from "./components/ResultView.tsx";
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
  | { status: "failed"; input: SceneInput; failure: Failure };

interface Shown extends Placement {
  saved: boolean;
  /** Changes for every new answer, so its entrance plays again. */
  key: number;
}

function savedAnswer(sample: Sample): Placement {
  return { result: parseResult(JSON.parse(sample.savedResult)), plan: sample.savedPlan };
}

export function App() {
  const [server, setServer] = useState(() => localStorage.getItem(SERVER_KEY) ?? DEFAULT_SERVER);
  const [health, setHealth] = useState<Health | null>(null);
  const [view, setView] = useState<View>({ status: "empty" });
  const inFlight = useRef<AbortController | null>(null);
  const sheet = useRef<HTMLElement>(null);
  const answers = useRef(0);

  useEffect(() => {
    const controller = new AbortController();
    setHealth(null);
    checkHealth(server, controller.signal).then((next) => {
      if (!controller.signal.aborted) {
        setHealth(next);
      }
    });
    return () => controller.abort();
  }, [server]);

  const solve = useCallback(
    async (input: SceneInput) => {
      inFlight.current?.abort();
      const controller = new AbortController();
      inFlight.current = controller;
      setView((current) => ({
        status: "loading",
        input,
        previous: current.status === "shown" ? current.shown : null,
      }));
      try {
        const placement = await requestPlacement(server, input, controller.signal);
        answers.current += 1;
        setView({
          status: "shown",
          input,
          shown: { ...placement, saved: false, key: answers.current },
        });
        setHealth((current) => (current?.ok ? current : null));
      } catch (error) {
        if (controller.signal.aborted) {
          return;
        }
        const failure: Failure =
          error instanceof PlacementError
            ? error.failure
            : {
                kind: "unexpected",
                message: error instanceof Error ? error.message : String(error),
              };
        setView({ status: "failed", input, failure });
        if (failure.kind === "unreachable") {
          setHealth({ ok: false });
        }
      }
    },
    [server],
  );

  async function pickFile(file: File) {
    try {
      await solve(await sceneFromFile(file));
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      setView({
        status: "failed",
        input: { name: file.name, body: file, contentType: "application/json", sampleId: null },
        failure: { kind: "unexpected", message },
      });
    }
  }

  function showSaved(sample: Sample, input: SceneInput) {
    answers.current += 1;
    setView({
      status: "shown",
      input,
      shown: { ...savedAnswer(sample), saved: true, key: answers.current },
    });
  }

  function pickSample(sample: Sample) {
    // The address names the sample, so a link opens the same answer.
    const url = new URL(window.location.href);
    url.searchParams.set("sample", sample.id);
    window.history.replaceState(null, "", url);
    solve(sceneFromSample(sample.id, sample.title, sample.scene));
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

  function changeServer(next: string) {
    localStorage.setItem(SERVER_KEY, next);
    setServer(next);
  }

  // On a phone the scene list sits above the sheet, so bring a new answer into view.
  useEffect(() => {
    if (view.status !== "shown" && view.status !== "failed") {
      return;
    }
    const top = sheet.current?.getBoundingClientRect().top ?? 0;
    if (top > window.innerHeight * 0.6) {
      const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
      sheet.current?.scrollIntoView({ behavior: reduce ? "auto" : "smooth", block: "start" });
    }
  }, [view.status]);

  const input = view.status === "empty" ? null : view.input;
  const shown =
    view.status === "shown" ? view.shown : view.status === "loading" ? view.previous : null;

  return (
    <div className="page">
      <header className="bar">
        <p className="brand">
          Placement review <span className="brand-sub">House Scan</span>
        </p>
        <ServerSetting server={server} health={health} onChange={changeServer} />
      </header>
      <main className="layout">
        <aside className="aside">
          <ScenePanel
            activeSampleId={input?.sampleId ?? null}
            fileName={input && input.sampleId === null ? input.name : null}
            onSample={pickSample}
            onFile={pickFile}
          />
        </aside>
        <section
          ref={sheet}
          className="sheet"
          aria-live="polite"
          aria-busy={view.status === "loading"}
        >
          {view.status === "loading" && (
            <div className="progress" role="progressbar" aria-label="Asking the placement server" />
          )}
          {view.status === "empty" && <EmptyView />}
          {view.status === "failed" && (
            <FailureView
              failure={view.failure}
              sample={SAMPLES.find((s) => s.id === view.input.sampleId) ?? null}
              onRetry={() => solve(view.input)}
              onSaved={(sample) => showSaved(sample, view.input)}
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
      <h1>Where does the battery go?</h1>
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
  onRetry: () => void;
  onSaved: (sample: Sample) => void;
}

function FailureView({ failure, sample, onRetry, onSaved }: FailureProps) {
  return (
    <div className="failure" role="alert">
      {failure.kind === "unreachable" && (
        <>
          <h1>Can't reach the placement server</h1>
          <p>
            Nothing answered at <code>{failure.server}</code>. Start the server with{" "}
            <code>uv run uvicorn api:app --port 8000</code> in <code>server/</code>, or point this
            page at another one with Change above.
          </p>
          <p className="detail">{failure.detail}</p>
        </>
      )}
      {failure.kind === "refused" && (
        <>
          <h1>The server refused this scene</h1>
          <p>{failure.message}</p>
          <p className="detail">
            {failure.code}
            {failure.path ? ` at ${failure.path}` : ""}
          </p>
        </>
      )}
      {failure.kind === "unexpected" && (
        <>
          <h1>That didn't work</h1>
          <p>{failure.message}</p>
        </>
      )}
      <div className="actions">
        <button type="button" className="button" onClick={onRetry}>
          Try again
        </button>
        {sample && failure.kind === "unreachable" && (
          <button type="button" className="button quiet" onClick={() => onSaved(sample)}>
            Show the saved answer
          </button>
        )}
      </div>
    </div>
  );
}
