import { describe, expect, it } from "vitest";
import { feet, fromMeter, measured } from "./format.ts";

describe("feet", () => {
  it.each([
    [2.75, "2 ft 9 in"],
    [3, "3 ft"],
    [7 / 12, "7 in"],
    [-9.675, "9 ft 8 in"],
    [0.99, "1 ft"],
  ])("%d ft reads %s", (value, text) => {
    expect(feet(value)).toBe(text);
  });
});

describe("measured", () => {
  it("adds the error when there is one", () => {
    expect(measured(9.675, 7 / 12)).toBe("9 ft 8 in ± 7 in");
  });

  it("leaves it out when the value is exact", () => {
    expect(measured(6, 0)).toBe("6 ft");
    expect(measured(6, null)).toBe("6 ft");
  });
});

describe("fromMeter", () => {
  it("says which side", () => {
    expect(fromMeter(-10)).toBe("10 ft left of the meter");
    expect(fromMeter(2.75)).toBe("2 ft 9 in right of the meter");
    expect(fromMeter(0.01)).toBe("at the meter");
  });
});
