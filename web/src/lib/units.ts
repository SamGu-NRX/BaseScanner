// ARKit reports lengths in meters; people read feet and inches.
// Both constants are exact by definition (international yard and pound, 1959).
const METERS_PER_FOOT = 0.3048;
const METERS_PER_INCH = 0.0254;
const INCHES_PER_FOOT = 12;

// These lengths are distances, so every function rejects negative and
// non-finite input instead of formatting a meaningless value.
function assertLength(value: number, name: string): void {
  if (!Number.isFinite(value)) {
    throw new RangeError(`${name} must be a finite number, got ${value}`);
  }
  if (value < 0) {
    throw new RangeError(`${name} must not be negative, got ${value}`);
  }
}

export function metersToFeet(m: number): number {
  assertLength(m, "meters");
  return m / METERS_PER_FOOT;
}

export function feetToMeters(ft: number): number {
  assertLength(ft, "feet");
  return ft * METERS_PER_FOOT;
}

/**
 * Formats a length in meters as whole feet and inches, e.g. "8 ft 4 in".
 * Rounds to the nearest inch (half an inch rounds up) before splitting, so
 * 11.81 in reads "1 ft 0 in" rather than "0 ft 12 in".
 */
export function formatFeetInches(m: number): string {
  assertLength(m, "meters");
  const totalInches = Math.round(m / METERS_PER_INCH);
  const feet = Math.floor(totalInches / INCHES_PER_FOOT);
  const inches = totalInches % INCHES_PER_FOOT;
  return `${feet} ft ${inches} in`;
}
