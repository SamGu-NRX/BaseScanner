import { describe, expect, it } from "vitest";
import { type Failure, PlacementError } from "./api.ts";
import { HOST_LIMIT_BYTES, sceneFromFile } from "./scene-input.ts";

async function refusal(file: File): Promise<Failure> {
  try {
    await sceneFromFile(file);
  } catch (error) {
    if (error instanceof PlacementError) {
      return error.failure;
    }
    throw error;
  }
  throw new Error("expected a PlacementError");
}

const ZIP_HEAD = new Uint8Array([0x50, 0x4b, 0x03, 0x04]);

describe("sceneFromFile", () => {
  it("sends a zip bundle as a zip, whatever its name", async () => {
    const file = new File([new Uint8Array([0x50, 0x4b, 0x03, 0x04, 0])], "capture.bin");
    expect((await sceneFromFile(file)).contentType).toBe("application/zip");
  });

  it("sends scene.json as JSON", async () => {
    const file = new File(["{}"], "scene.json");
    expect((await sceneFromFile(file)).contentType).toBe("application/json");
  });

  it("refuses anything else by name", async () => {
    await expect(sceneFromFile(new File(["x"], "photo.jpg"))).rejects.toThrow(
      "photo.jpg is neither a scene.json nor a zip bundle.",
    );
  });

  // The hosted server's host refuses larger bodies without CORS headers, so the browser would
  // only see a network error; the page has to refuse them before sending.
  it("refuses a zip over the host's limit and says scene.json alone is enough", async () => {
    const file = new File([ZIP_HEAD, new Uint8Array(HOST_LIMIT_BYTES)], "capture.zip");
    const failure = await refusal(file);
    expect(failure.kind).toBe("too_large");
    expect(failure.kind === "too_large" && failure.message).toMatch(/scene\.json on its own/);
  });

  it("refuses a scene.json over the host's limit", async () => {
    const file = new File([new Uint8Array(HOST_LIMIT_BYTES + 1)], "scene.json");
    expect((await refusal(file)).kind).toBe("too_large");
  });

  it("sends a file right at the limit", async () => {
    const file = new File([new Uint8Array(HOST_LIMIT_BYTES)], "scene.json");
    expect((await sceneFromFile(file)).body.size).toBe(HOST_LIMIT_BYTES);
  });
});
