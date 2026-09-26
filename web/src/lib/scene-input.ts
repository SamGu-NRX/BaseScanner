/** A scene ready to send: the bytes, how to label them, and where it came from. */
export interface SceneInput {
  name: string;
  body: Blob;
  contentType: "application/json" | "application/zip";
  /** Set for a bundled sample, which also has a saved answer. */
  sampleId: string | null;
}

const ZIP_MAGIC = [0x50, 0x4b, 0x03, 0x04]; // "PK\x03\x04"

/** A picked or dropped file: a scene bundle (zip) or bare scene.json. */
export async function sceneFromFile(file: File): Promise<SceneInput> {
  const head = new Uint8Array(await file.slice(0, ZIP_MAGIC.length).arrayBuffer());
  const isZip = ZIP_MAGIC.every((byte, i) => head[i] === byte);
  if (!isZip && !file.name.toLowerCase().endsWith(".json")) {
    throw new Error(`${file.name} is neither a scene.json nor a zip bundle.`);
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
