/** A scene ready to send: the bytes, how to label them, and where it came from. */
export interface SceneInput {
  name: string;
  body: Blob;
  contentType: "application/json" | "application/zip";
  /** Set for a bundled sample, which also has a saved answer. */
  sampleId: string | null;
}

import { PlacementError } from "./api.ts";

/** Vercel, which hosts the placement server, refuses request bodies over 4.5 MB, and its refusal
 * has no CORS headers, so the browser reports only a network error. Refusing here instead says
 * what happened. */
export const HOST_LIMIT_BYTES = 4_500_000;

const ZIP_MAGIC = [0x50, 0x4b, 0x03, 0x04]; // "PK\x03\x04"

/** A picked or dropped file: a scene bundle (zip) or bare scene.json. */
export async function sceneFromFile(file: File): Promise<SceneInput> {
  const head = new Uint8Array(await file.slice(0, ZIP_MAGIC.length).arrayBuffer());
  const isZip = ZIP_MAGIC.every((byte, i) => head[i] === byte);
  if (!isZip && !file.name.toLowerCase().endsWith(".json")) {
    throw new Error(`${file.name} is neither a scene.json nor a zip bundle.`);
  }
  if (file.size > HOST_LIMIT_BYTES) {
    const size = `${(file.size / 1_000_000).toFixed(1)} MB`;
    throw new PlacementError({
      kind: "too_large",
      message: isZip
        ? `${file.name} is ${size}, and the server accepts at most 4.5 MB. The placement reads only scene.json, so send scene.json on its own, without the photos.`
        : `${file.name} is ${size}, and the server accepts at most 4.5 MB.`,
    });
  }
  return {
    name: file.name,
    body: file,
    contentType: isZip ? "application/zip" : "application/json",
    sampleId: null,
  };
}

export function sceneFromSample(id: string, name: string, sceneJson: string): SceneInput {
  return {
    name,
    body: new Blob([sceneJson], { type: "application/json" }),
    contentType: "application/json",
    sampleId: id,
  };
}
