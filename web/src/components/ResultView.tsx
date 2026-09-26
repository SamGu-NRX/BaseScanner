import { useMemo } from "react";
import type { Result } from "../lib/api.ts";
import { feet, fromMeter, measured } from "../lib/format.ts";

type Check = Result["checks"][number];

export const STAMP: Record<Result["decision"], string> = {
  pass: "Fits",
  manual_review: "Needs review",
  reject: "No spot",
};

const CAUSE: Record<NonNullable<Check["unsure_cause"]>, string> = {
  margin: "Too close to call",
  unobserved: "Not seen",
  unknown_attribute: "Detail missing",
  rule_requires_review: "Policy asks a person",
};

const OUTCOME_WORD: Record<Check["outcome"], string> = {
  pass: "Pass",
  unsure: "Unsure",
  fail: "Fail",
};

interface Props {
  result: Result;
  plan: string | null;
  saved: boolean;
  /** "full" when an answer appears; "stamp" when it replaces another, so only the stamp lands. */
  entrance: "full" | "stamp";
}

/** The SVG's own width and height, so the image reserves its space before it decodes. */
function planSize(svg: string): { width: number; height: number } | null {
  const root = new DOMParser().parseFromString(svg, "image/svg+xml").documentElement;
  const width = Number(root.getAttribute("width"));
  const height = Number(root.getAttribute("height"));
  return width > 0 && height > 0 ? { width, height } : null;
}

function planAlt(result: Result): string {
  const spot = result.spot;
  const where = spot
    ? `the battery ${fromMeter((spot.span_ft[0] + spot.span_ft[1]) / 2)}`
    : "no battery spot";
  const cable = result.route ? `, and a ${feet(result.route.length_ft)} cable run` : "";
  return `Site plan from above: the scanned wall and the meter, ${where}${cable}.`;
}

export function ResultView({ result, plan, saved, entrance }: Props) {
  const spot = result.spot ?? result.nearest_considered ?? null;
  const attention = result.checks.filter((c) => c.outcome !== "pass");
  const passing = result.checks.length - attention.length;
  const views = result.missing_evidence;
  const size = useMemo(() => (plan ? planSize(plan) : null), [plan]);

  return (
    <article className="result" data-entrance={entrance}>
      <header className="verdict">
        <h2 className="stamp" data-decision={result.decision}>
          {STAMP[result.decision]}
        </h2>
        <div className="verdict-text">
          <p className="summary">{result.summary}</p>
          <p className="source">
            {saved ? "Saved answer" : "Live answer"} · rules {result.policy.id ?? "none"}
            {result.policy.version ? ` v${result.policy.version}` : ""}
            {result.policy.auto_approve ? "" : " (not approved for automatic decisions)"}
          </p>
        </div>
      </header>

      <dl className="facts reveal">
        <div>
          <dt>{result.spot ? "Battery" : "Closest spot tried"}</dt>
          <dd>{spot ? fromMeter((spot.span_ft[0] + spot.span_ft[1]) / 2) : "None"}</dd>
        </div>
        <div>
          <dt>Cable run</dt>
          <dd>
            {result.route
              ? measured(result.route.length_ft, result.route.plus_minus_ft)
              : spot?.route_length_ft != null
                ? feet(spot.route_length_ft)
                : "None"}
          </dd>
        </div>
        <div>
          <dt>Checks</dt>
          <dd>
            {passing} of {result.checks.length} pass
          </dd>
        </div>
      </dl>

      <figure className="plan reveal">
        {plan ? (
          <img
            src={`data:image/svg+xml;charset=utf-8,${encodeURIComponent(plan)}`}
            alt={planAlt(result)}
            width={size?.width}
            height={size?.height}
          />
        ) : (
          <p className="plan-missing">The server did not send a site plan for this answer.</p>
        )}
      </figure>

      {attention.length > 0 && (
        <section className="block reveal" aria-labelledby="attention-title">
          <h2 id="attention-title">Needs a look</h2>
          <ul className="checks">
            {attention.map((check) => (
              <CheckRow key={check.id} check={check} />
            ))}
          </ul>
        </section>
      )}

      {views.length > 0 && (
        <section className="block reveal" aria-labelledby="views-title">
          <h2 id="views-title">Views to add</h2>
          <ol className="views">
            {views.map((view) => (
              <li key={`${view.kind}-${view.band ?? view.side}-${view.span_ft?.join()}`}>
                {view.message}
              </li>
            ))}
          </ol>
        </section>
      )}

      <details className="block all-checks reveal">
        <summary>All {result.checks.length} checks</summary>
        <ul className="checks">
          {result.checks.map((check) => (
            <CheckRow key={check.id} check={check} />
          ))}
        </ul>
      </details>
    </article>
  );
}

function limitText(check: Check): string | null {
  if (check.threshold_ft == null) {
    return null;
  }
  if (check.comparison === "at_most") {
    const review =
      check.review_threshold_ft == null ? "" : `, review past ${feet(check.review_threshold_ft)}`;
    return `max ${feet(check.threshold_ft)}${review}`;
  }
  return `needs more than ${feet(check.threshold_ft)}`;
}

function CheckRow({ check }: { check: Check }) {
  const limit = limitText(check);
  return (
    <li className="check" data-outcome={check.outcome}>
      <span className="outcome" aria-hidden="true" />
      <div className="check-body">
        <p className="check-head">
          <span className="check-label">{check.label}</span>
          <span className="visually-hidden">: {OUTCOME_WORD[check.outcome]}</span>
          {check.unsure_cause && <span className="cause">{CAUSE[check.unsure_cause]}</span>}
        </p>
        {check.measured_ft != null && (
          <p className="figure">
            {measured(check.measured_ft, check.plus_minus_ft)}
            {limit && <span className="limit"> · {limit}</span>}
          </p>
        )}
        <p className="reason">{check.reason}</p>
      </div>
    </li>
  );
}
