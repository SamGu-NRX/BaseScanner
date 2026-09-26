import type { BatteryPlacementResult } from "../contract/result.ts";
import validate from "../contract/validate-result.js";
import type { SceneInput } from "./scene-input.ts";

export type Result = BatteryPlacementResult;

/** Why a placement could not be shown. Each kind is a different message and a different fix. */
export type Failure =
  | { kind: "unreachable"; server: string; detail: string }
  | { kind: "refused"; code: string; message: string; path: string | null }
  | { kind: "unexpected"; message: string };

export class PlacementError extends Error {
  readonly failure: Failure;

  constructor(failure: Failure) {
    super(failure.kind === "unreachable" ? failure.detail : failure.message);
    this.failure = failure;
  }
}

export interface Placement {
  result: Result;
  /** The site plan SVG, or null when the server gave the result but not the plan. */
  plan: string | null;
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
  return new PlacementError({
    kind: "unreachable",
    server,
    detail: `HTTP ${response.status} without a placement error, so this is probably not the placement server.`,
  });
}

export async function requestPlacement(
  server: string,
  input: SceneInput,
  signal: AbortSignal,
): Promise<Placement> {
  const [answer, planAnswer] = await Promise.all([
    post(server, "/v1/placements", input, signal),
    post(server, "/v1/placements/site-plan.svg", input, signal).catch((error: unknown) => {
      if (signal.aborted) {
        throw error;
      }
      return null;
    }),
  ]);
  if (!answer.ok) {
    throw await failureFrom(answer, server);
  }
  const body = await readJson(answer);
  if (body === undefined) {
    throw new PlacementError({ kind: "unexpected", message: "The answer is not JSON." });
  }
  const result = parseResult(body);
  const plan = planAnswer?.ok ? await planAnswer.text() : null;
  return { result, plan };
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
      typeof policy === "object" && policy !== null && "id" in policy ? String(policy.id) : "?";
    return { ok: true, policy: id };
  } catch {
    return { ok: false };
  }
}
