// Generated from result.schema.json by `pnpm contract`. Do not edit by hand.

export type Outcome = "pass" | "fail" | "unsure";
/**
 * Battery's stretch of wall in s, left edge first.
 *
 * @minItems 2
 * @maxItems 2
 */
export type Span = [number, number];
/**
 * @minItems 2
 * @maxItems 2
 */
export type Point2 = [number, number];
/**
 * Plan centre of the footprint.
 *
 * @minItems 2
 * @maxItems 2
 */
export type Point21 = [number, number];
/**
 * Unit vector along the wall toward +s.
 *
 * @minItems 2
 * @maxItems 2
 */
export type Point22 = [number, number];
/**
 * Unit vector from the wall out toward the battery's front.
 *
 * @minItems 2
 * @maxItems 2
 */
export type Point23 = [number, number];
/**
 * @minItems 2
 * @maxItems 2
 */
export type Span1 = [number, number];
/**
 * Range of battery start positions (left edge, in s) in this run. Stretches too far along the wall for any cable route are one failing run, not evaluated start by start.
 *
 * @minItems 2
 * @maxItems 2
 */
export type Span2 = [number, number];

/**
 * The placement server's answer for one scene (contract C2). Lengths are in feet; plan coordinates [x, z] and s follow scene.schema.json. The result settles placement only, never the whole installation: electrical checks (panel, meter) are outside it.
 */
export interface BatteryPlacementResult {
  schema_version: string;
  /**
   * pass: a fully observed spot passes every check under an approved policy. manual_review: a person must decide, because the best spot has an UNSURE check, the policy is not approved for automatic decisions, or an area that could hold a valid spot was not seen. reject: every spot within reach fails by a clear margin, and both ends of the walk are known.
   */
  decision: "pass" | "manual_review" | "reject";
  /**
   * One sentence for the homeowner or reviewer.
   */
  summary: string;
  reasons: {
    code:
      | "all_checks_pass"
      | "policy_not_approved"
      | "unsure_checks"
      | "unobserved_area"
      | "unexplored_end"
      | "all_spots_fail"
      | "no_wall_segment_fits";
    message: string;
    /**
     * Check ids behind this reason.
     */
    checks?: string[];
  }[];
  policy: {
    id: string | null;
    version: string | null;
    /**
     * Whether the rules allow automatic decisions: false when no policy is selected or the rules file sets auto_approve false (the public rules.yaml does, because it holds placeholder values). When false, every would-be pass or reject becomes manual_review. Each check's rule.placeholder says which values decided it.
     */
    auto_approve: boolean;
    /**
     * Which rules files were loaded.
     */
    sources: ("public" | "private")[];
    /**
     * Hash of the merged rules the decision used.
     */
    rules_sha256: string;
  };
  /**
   * The chosen battery position: the best passing spot, or for manual_review the best spot with no failing check. Null when no such spot exists, including every reject.
   */
  spot: null | Spot;
  /**
   * Cable route from the meter to the chosen spot. Null when `spot` is null.
   */
  route: null | Route;
  /**
   * Every check at the chosen spot, or, when `spot` is null, at `nearest_considered`.
   */
  checks: Check[];
  /**
   * When `spot` is null: the evaluated spot closest to passing (fewest failing checks, then fewest unsure, then shortest route), whose checks explain why it fails. Null otherwise.
   */
  nearest_considered?: null | Spot;
  /**
   * Views that would settle an UNSURE result. Only areas nobody observed appear here; an UNSURE caused by a measurement inside its error band needs a person, not more photos. Empty for pass and reject.
   */
  missing_evidence: {
    kind: "band" | "past_end";
    band?: "wall" | "ground" | "overhead" | "facing";
    span_ft?: Span1;
    side?: "left" | "right";
    checks?: string[];
    message: string;
  }[];
  ends: {
    left: End;
    right: End;
  };
  /**
   * Outcome of every battery start position along the wall, merged into runs of equal outcome. Shows why each stretch fails; the site plan colours the wall with it.
   */
  sweep: {
    wall_id: string;
    /**
     * Straight baseline segment of `wall_id`; runs never cross a corner.
     */
    segment?: number;
    start_ft: Span2;
    outcome: Outcome;
    failing: string[];
    unsure: string[];
  }[];
  stats: {
    candidates: number;
    pass: number;
    unsure: number;
    fail: number;
    elapsed_ms: number;
    /**
     * Hash of the scene JSON as uploaded.
     */
    input_sha256: string;
  };
}
export interface Spot {
  outcome: Outcome;
  wall_id: string;
  /**
   * Index of the straight baseline segment of `wall_id` the battery backs onto.
   */
  segment: number;
  span_ft: Span;
  width_ft: number;
  depth_ft: number;
  height_ft: number;
  /**
   * Plan corners [x, z]: back-left, back-right, front-right, front-left.
   *
   * @minItems 4
   * @maxItems 4
   */
  footprint: [Point2, Point2, Point2, Point2];
  center: Point21;
  along: Point22;
  outward: Point23;
  /**
   * Footprint centre minus the meter's plan position, [dx, dz] in the scene frame's axes. scene.json carries no ground height, so the app sets the height by resting the box on its detected ground plane. Attach AR content to the meter's anchor with this offset, rotated by the anchor's orientation if the anchor is not axis-aligned with the scene frame.
   *
   * @minItems 2
   * @maxItems 2
   */
  meter_offset_ft: [number, number];
  route_length_ft: number | null;
}
export interface Route {
  outcome: Outcome;
  /**
   * Length along the supported wall from the meter to the battery's near edge, including detours around wall objects.
   */
  length_ft: number;
  plus_minus_ft: number;
  /**
   * Height above ground the cable runs at, from the rules.
   */
  height_ft: number;
  /**
   * Plan points from the meter along the wall to the battery.
   */
  polyline: Point2[];
  detours: {
    subject: string;
    extra_ft: number;
  }[];
  crossings: {
    subject: string;
    span_ft: Span1;
    effect: "fail" | "review" | "detour" | "allow";
  }[];
}
export interface Check {
  /**
   * Stable identifier, for example gas_clearance or route_length.
   */
  id: string;
  label: string;
  outcome: Outcome;
  /**
   * Only for unsure. margin: measured inside the error band, a person must judge. unobserved: the deciding area was not seen, more photos fix it. unknown_attribute: a fact the camera did not establish (for example whether a window opens). rule_requires_review: the policy sends this situation to a person (for example a cable routed over a door).
   */
  unsure_cause?: "margin" | "unobserved" | "unknown_attribute" | "rule_requires_review";
  reason: string;
  /**
   * The deciding measurement, for example the gap to the nearest gas meter. Null when nothing relevant was found or it was not observed.
   */
  measured_ft: number | null;
  plus_minus_ft: number | null;
  threshold_ft: number | null;
  /**
   * Present on checks with a review band (route_length): a value that doesn't clear this line (at_most: measured + error < review_threshold_ft) is at best unsure, even when it clears threshold_ft. Same convention as the scoring harness's review_threshold.
   */
  review_threshold_ft?: number;
  /**
   * at_least: pass needs measured - error > threshold. at_most: pass needs measured + error < threshold.
   */
  comparison: "at_least" | "at_most" | null;
  /**
   * What the measurement is to, for example "objects[2] gas_meter".
   */
  subject?: string | null;
  rule: {
    /**
     * Parameter name in rules.yaml.
     */
    key: string;
    /**
     * Citation for the value.
     */
    source: string;
    /**
     * True for a demo value with no public source.
     */
    placeholder: boolean;
  };
}
export interface End {
  kind: "limit" | "unexplored";
  /**
   * Where the wall chain ends, in s.
   */
  s_ft: number;
  point: Point2;
  /**
   * True when this end is so far along the wall that no spot past it could pass the route-length check, so an unexplored end there does not block a reject.
   */
  beyond_reach?: boolean;
}
