import { describe, expect, it } from "vitest";
import { sceneFromFile } from "./scene-input.ts";

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
});
