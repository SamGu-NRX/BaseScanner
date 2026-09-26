import { type FormEvent, useEffect, useRef, useState } from "react";
import { type Health, isMixedContent } from "../lib/api.ts";

interface Props {
  server: string;
  health: Health | null;
  onChange: (server: string) => void;
}

export function ServerSetting({ server, health, onChange }: Props) {
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState(server);
  const changeButton = useRef<HTMLButtonElement>(null);
  const wasEditing = useRef(false);

  // Closing the form unmounts the focused control; give focus back to Change.
  useEffect(() => {
    if (wasEditing.current && !editing) {
      changeButton.current?.focus();
    }
    wasEditing.current = editing;
  }, [editing]);

  function save(event: FormEvent) {
    event.preventDefault();
    onChange(draft.trim() || server);
    setEditing(false);
  }

  const pageProtocol = window.location.protocol;
  const draftBlocked = isMixedContent(draft, pageProtocol);
  const status = health === null ? "checking" : health.ok ? "up" : "down";
  const statusText =
    health === null
      ? "Checking…"
      : health.ok
        ? `Connected · rules ${health.policy}`
        : isMixedContent(server, pageProtocol)
          ? "Blocked: an http server from this https page"
          : "Not reachable";

  if (editing) {
    return (
      <form
        className="server server-form"
        onSubmit={save}
        onKeyDown={(event) => {
          if (event.key === "Escape") {
            setEditing(false);
          }
        }}
      >
        <label htmlFor="server-url">Placement server</label>
        <input
          id="server-url"
          value={draft}
          onChange={(event) => setDraft(event.target.value)}
          placeholder="http://localhost:8000"
          // biome-ignore lint/a11y/noAutofocus: the field is what Change opened.
          autoFocus
          spellCheck={false}
          autoComplete="off"
          autoCapitalize="none"
          autoCorrect="off"
          inputMode="url"
          enterKeyHint="done"
          aria-describedby={draftBlocked ? "server-url-warning" : undefined}
        />
        <button type="submit" className="button">
          Use
        </button>
        <button type="button" className="button quiet" onClick={() => setEditing(false)}>
          Cancel
        </button>
        {draftBlocked && (
          <p id="server-url-warning" className="server-warning">
            This page is loaded over https, so the browser will block an http:// server. Use an
            https address.
          </p>
        )}
      </form>
    );
  }

  return (
    <div className="server">
      <span className="status-dot" data-status={status} aria-hidden="true" />
      <span className="server-text">
        <span className="server-url">{server}</span>
        <span className="server-status">{statusText}</span>
      </span>
      <button
        ref={changeButton}
        type="button"
        className="button quiet"
        onClick={() => {
          setDraft(server);
          setEditing(true);
        }}
      >
        Change
      </button>
    </div>
  );
}
