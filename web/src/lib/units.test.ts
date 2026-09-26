import { describe, expect, it } from "vitest";
import { feetToMeters, formatFeetInches, metersToFeet } from "./units.ts";

describe("metersToFeet", () => {
  it("converts exact multiples of a foot", () => {
    expect(metersToFeet(0.3048)).toBe(1);
    expect(metersToFeet(0.9144)).toBe(3);
    expect(metersToFeet(3.048)).toBe(10);
  });

  it("returns 0 for 0", () => {
    expect(metersToFeet(0)).toBe(0);
  });
});

describe("feetToMeters", () => {
  it("uses 1 ft = 0.3048 m exactly", () => {
    expect(feetToMeters(1)).toBe(0.3048);
    expect(feetToMeters(10)).toBe(3.048);
    expect(feetToMeters(3)).toBeCloseTo(0.9144, 12);
  });

  it("returns 0 for 0", () => {
    expect(feetToMeters(0)).toBe(0);
  });

  it("round-trips through metersToFeet", () => {
    expect(metersToFeet(feetToMeters(7.25))).toBeCloseTo(7.25, 12);
  });
});

describe("formatFeetInches", () => {
  it.each([
    [0.3048, "1 ft 0 in"],
    [0.9144, "3 ft 0 in"],
    [2.54, "8 ft 4 in"],
    [0.0254, "0 ft 1 in"],
  ])("formats %s m as %s", (m, expected) => {
    expect(formatFeetInches(m)).toBe(expected);
  });

  it("carries 12 rounded inches into the next foot", () => {
    // 0.3 m is 11.81 in, which rounds to 12 in.
    expect(formatFeetInches(0.3)).toBe("1 ft 0 in");
    // 3.35 m is 131.89 in, which rounds to 132 in.
    expect(formatFeetInches(3.35)).toBe("11 ft 0 in");
  });

  it("formats zero", () => {
    expect(formatFeetInches(0)).toBe("0 ft 0 in");
  });

  it("rounds half an inch up", () => {
    expect(formatFeetInches(0.0127)).toBe("0 ft 1 in"); // 0.5 in
    expect(formatFeetInches(0.1651)).toBe("0 ft 7 in"); // 6.5 in
    expect(formatFeetInches(0.3175)).toBe("1 ft 1 in"); // 12.5 in
  });

  it("rounds just under half an inch down", () => {
    expect(formatFeetInches(0.0126)).toBe("0 ft 0 in"); // 0.496 in
    expect(formatFeetInches(0.3174)).toBe("1 ft 0 in"); // 12.496 in
  });

  it("rounds every half inch up from 0.5 in to 1999.5 in", () => {
    for (let n = 0; n < 2000; n++) {
      // Build the decimal literal a caller would write, e.g. 0.0381 for 1.5 in.
      const m = Number((((2 * n + 1) * 127) / 10000).toFixed(7));
      const total = n + 1;
      const expected = `${Math.floor(total / 12)} ft ${total % 12} in`;
      expect(formatFeetInches(m), `${m} m`).toBe(expected);
    }
  });

  it("uses ASCII only", () => {
    expect(formatFeetInches(2.54)).toMatch(/^[\x20-\x7e]+$/);
  });
});

describe("input validation", () => {
  const invalid = [-0.01, -1, Number.NaN, Number.POSITIVE_INFINITY, Number.NEGATIVE_INFINITY];

  it.each(invalid)("formatFeetInches(%s) throws RangeError", (value) => {
    expect(() => formatFeetInches(value)).toThrow(RangeError);
  });

  it.each(invalid)("metersToFeet(%s) throws RangeError", (value) => {
    expect(() => metersToFeet(value)).toThrow(RangeError);
  });

  it.each(invalid)("feetToMeters(%s) throws RangeError", (value) => {
    expect(() => feetToMeters(value)).toThrow(RangeError);
  });
});
