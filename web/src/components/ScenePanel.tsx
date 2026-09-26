import { type DragEvent, useState } from "react";
import { SAMPLES, type Sample } from "../samples/index.ts";

interface Props {
  activeSampleId: string | null;
  fileName: string | null;
  onSample: (sample: Sample) => void;
  onFile: (file: File) => void;
}

export function ScenePanel({ activeSampleId, fileName, onSample, onFile }: Props) {
  const [dragging, setDragging] = useState(false);

  function drop(event: DragEvent) {
    event.preventDefault();
    setDragging(false);
    const file = event.dataTransfer.files[0];
    if (file) {
      onFile(file);
    }
  }

  return (
    <div className="scene-panel">
      <h2 className="panel-title">Scene</h2>
      <ul className="samples">
        {SAMPLES.map((sample) => (
          <li key={sample.id}>
            <button
              type="button"
              className="sample"
              aria-pressed={sample.id === activeSampleId}
              onClick={() => onSample(sample)}
            >
              <span className="sample-title">{sample.title}</span>
              <span className="sample-about">{sample.about}</span>
            </button>
          </li>
        ))}
      </ul>
      <label
        className="drop"
        data-dragging={dragging}
        onDragOver={(event) => {
          event.preventDefault();
          setDragging(true);
        }}
        onDragLeave={() => setDragging(false)}
        onDrop={drop}
      >
        <input
          type="file"
          accept=".json,.zip,application/json,application/zip"
          className="visually-hidden"
          onChange={(event) => {
            const file = event.target.files?.[0];
            if (file) {
              onFile(file);
            }
            event.target.value = "";
          }}
        />
        <span className="drop-title">{fileName ?? "Your own scan"}</span>
        <span className="drop-hint">Drop a scene.json or a zip bundle here, or choose a file.</span>
      </label>
    </div>
  );
}
