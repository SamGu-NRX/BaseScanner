import type { BatteryPlacementResult } from "../contract/result.ts";
import validate from "../contract/validate-result.js";
import type { SceneInput } from "./scene-input.ts";

export type Result = BatteryPlacementResult;

/** Why a placement could not be shown. Each kind is a different message and a different fix. */
export type Failure =
  /** No HTTP answer at all: the server is down, the address is wrong, or the browser blocked it. */
  | { kind: "unreachable"; server: string; detail: string }
  /** The placement server's own refusal, in its error format. */
  | { kind: "refused"; code: string; message: string; path: string | null }
  /** An HTTP error without the server's format: its host failed, or this is another site. */
  | { kind: "http_error"; server: string; status: number }
  /** Larger than the hosted server accepts, found by the page or by a readable 413. */
  | { kind: "too_large"; message: string }
  | { kind: "unexpected"; message: string };

export class PlacementError extends Error {
  readonly failure: Failure;

  constructor(failure: Failure) {
    super(failureText(failure));
    this.failure = failure;
  }
}

function failureText(failure: Failure): string {
  switch (failure.kind) {
    case "unreachable":
      return failure.detail;
    case "http_error":
      return `HTTP ${failure.status} from ${failure.server}`;
    default:
      return failure.message;
  }
}

/** Whether the browser will block calls to `server` from a page loaded over `pageProtocol`. */
export function isMixedContent(server: string, pageProtocol: string): boolean {
  return pageProtocol === "https:" && server.trim().toLowerCase().startsWith("http:");
}

/** Checks a parsed body against the result schema, so a contract break is a specific error. */
export function parseResult(body: unknown): Result {
  if (validate(body)) {
    return body;
  }
  const error = validate.errors?.[0];
  const where = error?.instancePath || "the top level";
  throw new PlacementError({
    kind: "unexpected",
    message: `The answer breaks the result contract at ${where}: ${error?.message ?? "unknown error"}.`,
  });
}

function joinUrl(server: string, path: string): string {
  return `${server.replace(/\/+$/, "")}${path}`;
}

async function post(server: string, path: string, input: SceneInput, signal: AbortSignal) {
  try {
    return await fetch(joinUrl(server, path), {
      method: "POST",
      headers: { "Content-Type": input.contentType },
      body: input.body,
      signal,
    });
  } catch (error) {
    if (signal.aborted) {
      throw error;
    }
    throw new PlacementError({
      kind: "unreachable",
      server,
      detail: error instanceof Error ? error.message : String(error),
    });
  }
}

interface ErrorEnvelope {
  error: { code: string; message: string; path: string | null };
}

function isErrorEnvelope(body: unknown): body is ErrorEnvelope {
  if (typeof body !== "object" || body === null || !("error" in body)) {
    return false;
  }
  const error = body.error;
  return (
    typeof error === "object" &&
    error !== null &&
    "code" in error &&
    typeof error.code === "string" &&
    "message" in error &&
    typeof error.message === "string"
  );
}

async function readJson(response: Response): Promise<unknown> {
  try {
    return await response.json();
  } catch {
    return undefined;
  }
}

/** A non-2xx answer: the server's own refusal, or something that is not the placement server. */
async function failureFrom(response: Response, server: string): Promise<PlacementError> {
  const body = await readJson(response);
  if (isErrorEnvelope(body)) {
    return new PlacementError({
      kind: "refused",
      code: body.error.code,
      message: body.error.message,
      path: body.error.path,
    });
  }
  if (response.status === 413) {
    // A host in front of the server refused it first (Vercel caps request bodies at 4.5 MB).
    return new PlacementError({
      kind: "too_large",
      message:
        "The upload is larger than the server accepts. Send scene.json on its own, or a zip without the photos: the placement doesn't use them.",
    });
  }
  return new PlacementError({ kind: "http_error", server, status: response.status });
}

/** Sends the scene once and returns the server's answer. */
export async function requestPlacement(
  server: string,
  input: SceneInput,
  signal: AbortSignal,
): Promise<Result> {
  const answer = await post(server, "/v1/placements", input, signal);
  if (!answer.ok) {
    throw await failureFrom(answer, server);
  }
  const body = await readJson(answer);
  if (body === undefined) {
    throw new PlacementError({ kind: "unexpected", message: "The answer is not JSON." });
  }
  return parseResult(body);
}

/** The site plan for a scene the server has already answered, or null when it can't be drawn.
 * The server has no endpoint returning both, so this sends the scene a second time; asking only
 * after an answer keeps a refused scene to one upload. */
export async function requestPlan(
  server: string,
  input: SceneInput,
  signal: AbortSignal,
): Promise<string | null> {
  try {
    const answer = await post(server, "/v1/placements/site-plan.svg", input, signal);
    return answer.ok ? await answer.text() : null;
  } catch (error) {
    if (signal.aborted) {
      throw error;
    }
    return null;
  }
}

export type Health = { ok: true; policy: string } | { ok: false };

/** Which rules the server has loaded, or that it did not answer. Never throws. */
export async function checkHealth(server: string, signal: AbortSignal): Promise<Health> {
  try {
    const response = await fetch(joinUrl(server, "/health"), { signal });
    const body = await readJson(response);
    if (!response.ok || typeof body !== "object" || body === null || !("policy" in body)) {
      return { ok: false };
    }
    const policy = body.policy;
    const id =
      typeof policy === "object" && policy !== null && "id" in policy
        ? String(policy.id)
        : "unnamed";
    return { ok: true, policy: id };
  } catch {
    return { ok: false };
  }
}
