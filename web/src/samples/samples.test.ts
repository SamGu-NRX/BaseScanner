import { describe, expect, it } from "vitest";
import { parseResult } from "../lib/api.ts";
import { SAMPLES } from "./index.ts";

// What the hosted server (public rules, demo policy) decides for each sample.
const DECISION: Record<string, string> = {
  fits: "pass",
  "corner-not-walked": "manual_review",
  "garage-in-the-way": "reject",
};

// A saved answer stands in for the live server, so it must be what the hosted server would say
// about the same scene.
describe.each(SAMPLES)("saved answer for $id", (sample) => {
  const result = parseResult(JSON.parse(sample.savedResult));

  it("was recorded under the hosted server's demo policy, and says so", () => {
    expect(result.policy).toMatchObject({ id: "demo", auto_approve: true, sources: ["public"] });
    expect(result.policy.notice).toMatch(/not Base's/);
  });

  it("gets the decision the hosted server gives it", () => {
    expect(result.decision).toBe(DECISION[sample.id]);
  });
});
