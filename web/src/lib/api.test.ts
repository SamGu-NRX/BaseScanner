import { afterEach, describe, expect, it, vi } from "vitest";
import fitsResult from "../samples/fits/result.json?raw";
import {
  type Failure,
  isMixedContent,
  PlacementError,
  parseResult,
  requestPlacement,
  requestPlan,
} from "./api.ts";
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
  it("sends the scene once and returns the result", async () => {
    stubFetch(() => new Response(fitsResult));
    const result = await requestPlacement("/api", input, new AbortController().signal);
    expect(result.decision).toBe("pass");
    expect(fetch).toHaveBeenCalledTimes(1);
  });

  it("sends a refused scene once", async () => {
    const envelope = { error: { code: "invalid_scene", message: "bad", path: "/walls/0" } };
    stubFetch(() => Response.json(envelope, { status: 422 }));
    await failureOf(requestPlacement("/api", input, new AbortController().signal));
    expect(fetch).toHaveBeenCalledTimes(1);
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
    expect(failure.kind).toBe("too_large");
  });

  it("tells an HTTP error without the server's format apart from no answer", async () => {
    stubFetch(() => new Response("<html>404</html>", { status: 404 }));
    const failure = await failureOf(requestPlacement("/api", input, new AbortController().signal));
    expect(failure).toEqual({ kind: "http_error", server: "/api", status: 404 });
  });

  it("reports a gateway timeout as an HTTP error, not an unreachable server", async () => {
    stubFetch(() => new Response("An error occurred", { status: 504 }));
    const failure = await failureOf(requestPlacement("/api", input, new AbortController().signal));
    expect(failure).toEqual({ kind: "http_error", server: "/api", status: 504 });
  });
});

describe("requestPlan", () => {
  it("returns the site plan", async () => {
    stubFetch(() => new Response("<svg/>"));
    expect(await requestPlan("/api", input, new AbortController().signal)).toBe("<svg/>");
  });

  it("returns null when the plan fails, so the result still shows", async () => {
    stubFetch(() => new Response("", { status: 500 }));
    expect(await requestPlan("/api", input, new AbortController().signal)).toBeNull();
  });

  it("returns null when the plan can't be fetched", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(() => Promise.reject(new TypeError("Failed to fetch"))),
    );
    expect(await requestPlan("/api", input, new AbortController().signal)).toBeNull();
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

  // A server can add fields within schema 1.x; the deployed page must keep reading its answers.
  it("accepts fields added within the same major schema version", () => {
    const answer = JSON.parse(fitsResult);
    const newer = {
      ...answer,
      schema_version: "1.3",
      added_later: { any: "shape" },
      policy: { ...answer.policy, added_later: true },
      checks: answer.checks.map((c: object) => ({ ...c, added_later: 1 })),
    };
    expect(parseResult(newer).schema_version).toBe("1.3");
  });

  it("refuses an answer from another major schema version", () => {
    const answer = { ...JSON.parse(fitsResult), schema_version: "2.0" };
    expect(() => parseResult(answer)).toThrow(/at \/schema_version/);
  });
});

describe("isMixedContent", () => {
  it("flags an http server from an https page", () => {
    expect(isMixedContent("http://192.168.1.20:8000", "https:")).toBe(true);
  });

  it.each([
    ["https://house-scanning-server.vercel.app", "https:"],
    ["/api", "https:"],
    ["http://localhost:8000", "http:"],
  ])("allows %s from an %s page", (server, protocol) => {
    expect(isMixedContent(server, protocol)).toBe(false);
  });
});
