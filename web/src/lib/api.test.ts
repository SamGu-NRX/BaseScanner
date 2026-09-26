import { afterEach, describe, expect, it, vi } from "vitest";
import fitsResult from "../samples/fits/result.json?raw";
import { type Failure, PlacementError, parseResult, requestPlacement } from "./api.ts";
import { sceneFromSample } from "./scene-input.ts";

const input = sceneFromSample("fits", "Clear side wall", "{}");

function stubFetch(answer: (url: string) => Response | Promise<Response>) {
  vi.stubGlobal(
    "fetch",
    vi.fn((url: string) => Promise.resolve(answer(url))),
  );
}

async function failureOf(promise: Promise<unknown>): Promise<Failure> {
  try {
    await promise;
  } catch (error) {
    if (error instanceof PlacementError) {
      return error.failure;
    }
    throw error;
  }
  throw new Error("expected a PlacementError");
}

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("requestPlacement", () => {
  it("returns the result and the site plan", async () => {
    stubFetch((url) => (url.endsWith(".svg") ? new Response("<svg/>") : new Response(fitsResult)));
    const placement = await requestPlacement("/api", input, new AbortController().signal);
    expect(placement.result.decision).toBe("pass");
    expect(placement.plan).toBe("<svg/>");
  });

  it("still shows the result when only the site plan fails", async () => {
    stubFetch((url) =>
      url.endsWith(".svg") ? new Response("", { status: 500 }) : new Response(fitsResult),
    );
    const placement = await requestPlacement("/api", input, new AbortController().signal);
    expect(placement.plan).toBeNull();
  });

  it("reports a refusal with the field at fault", async () => {
    const envelope = { error: { code: "invalid_scene", message: "bad", path: "/walls/0" } };
    stubFetch(() => Response.json(envelope, { status: 422 }));
    expect(await failureOf(requestPlacement("/api", input, new AbortController().signal))).toEqual({
      kind: "refused",
      code: "invalid_scene",
      message: "bad",
      path: "/walls/0",
    });
  });

  it("calls a network error unreachable", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(() => Promise.reject(new TypeError("Failed to fetch"))),
    );
    const failure = await failureOf(
      requestPlacement("http://localhost:8000", input, new AbortController().signal),
    );
    expect(failure).toMatchObject({ kind: "unreachable", server: "http://localhost:8000" });
  });

  it("explains an upload refused for size before it reached the server", async () => {
    stubFetch(() => new Response("Request Entity Too Large", { status: 413 }));
    const failure = await failureOf(requestPlacement("/api", input, new AbortController().signal));
    expect(failure).toMatchObject({ kind: "refused", code: "body_too_large" });
  });

  it("calls a page that is not the placement server unreachable", async () => {
    stubFetch(() => new Response("<html>404</html>", { status: 404 }));
    const failure = await failureOf(requestPlacement("/api", input, new AbortController().signal));
    expect(failure.kind).toBe("unreachable");
  });
});

describe("parseResult", () => {
  it("accepts a recorded answer", () => {
    expect(parseResult(JSON.parse(fitsResult)).schema_version).toBe("1.0");
  });

  it("names where an answer breaks the contract", () => {
    const broken = { ...JSON.parse(fitsResult), decision: "maybe" };
    expect(() => parseResult(broken)).toThrow(/at \/decision/);
  });
});
