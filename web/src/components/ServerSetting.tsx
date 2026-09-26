import { type FormEvent, useState } from "react";
import type { Health } from "../lib/api.ts";

interface Props {
  server: string;
  health: Health | null;
  onChange: (server: string) => void;
}

export function ServerSetting({ server, health, onChange }: Props) {
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState(server);

  function save(event: FormEvent) {
    event.preventDefault();
    onChange(draft.trim() || server);
    setEditing(false);
  }

  const status = health === null ? "checking" : health.ok ? "up" : "down";
  const statusText =
    health === null
      ? "Checking…"
      : health.ok
        ? `Connected · rules ${health.policy}`
        : "Not reachable";

  if (editing) {
    return (
      <form className="server server-form" onSubmit={save}>
        <label htmlFor="server-url">Placement server</label>
        <input
          id="server-url"
          value={draft}
          onChange={(event) => setDraft(event.target.value)}
          placeholder="http://localhost:8000"
          spellCheck={false}
          autoComplete="off"
        />
        <button type="submit" className="button">
          Use
        </button>
        <button type="button" className="button quiet" onClick={() => setEditing(false)}>
          Cancel
        </button>
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
