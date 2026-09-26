import { feetToMeters, formatFeetInches } from "./units.ts";

// The placement server reports feet. These read them the way a person says them.

/** "2 ft 9 in", "7 in", "3 ft". Absolute value: callers say which side. */
export function feet(value: number): string {
  const text = formatFeetInches(feetToMeters(Math.abs(value)));
  if (text.startsWith("0 ft ")) {
    return text.slice("0 ft ".length);
  }
  return text.endsWith(" 0 in") ? text.slice(0, -" 0 in".length) : text;
}

/** A measurement with its error: "9 ft 8 in ± 7 in", or just the length when the error is 0. */
export function measured(value: number, plusMinus: number | null | undefined): string {
  if (!plusMinus) {
    return feet(value);
  }
  return `${feet(value)} ± ${feet(plusMinus)}`;
}

/** Where a point along the wall is: s is feet from the meter, negative to the left. */
export function fromMeter(s: number): string {
  if (Math.abs(s) < 1 / 24) {
    return "at the meter";
  }
  return `${feet(s)} ${s < 0 ? "left" : "right"} of the meter`;
}
