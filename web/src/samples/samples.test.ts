import { describe, expect, it } from "vitest";
import { parseResult } from "../lib/api.ts";
import { SAMPLES } from "./index.ts";

// A saved answer stands in for the live server, so it must be what the hosted server (public rules
// only) would say about the same scene.
describe.each(SAMPLES)("saved answer for $id", (sample) => {
  const result = parseResult(JSON.parse(sample.savedResult));

  it("was recorded under the public rules", () => {
    expect(result.policy).toMatchObject({ id: "public-demo", auto_approve: false });
    expect(result.policy.sources).toEqual(["public"]);
  });

  it("does not claim a decision the public rules leave to a person", () => {
    expect(result.decision).toBe("manual_review");
  });
});
