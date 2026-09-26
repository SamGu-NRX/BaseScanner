import math

import pytest

from units import format_ft_in, ft_to_in, ft_to_m, in_to_ft, m_to_ft


def test_one_foot_is_exactly_0_3048_meters() -> None:
    assert ft_to_m(1) == 0.3048
    assert m_to_ft(0.3048) == 1.0


def test_meter_foot_round_trip_values() -> None:
    assert ft_to_m(10) == 3.048
    assert m_to_ft(3.048) == 10.0


def test_inch_foot_conversions() -> None:
    assert ft_to_in(1) == 12
    assert ft_to_in(0.5) == 6.0
    assert in_to_ft(6) == 0.5
    assert in_to_ft(12) == 1.0


def test_zero_converts_to_zero() -> None:
    assert m_to_ft(0) == 0.0
    assert ft_to_m(0) == 0.0
    assert in_to_ft(0) == 0.0
    assert ft_to_in(0) == 0.0
    assert format_ft_in(0) == "0 ft 0 in"


def test_format_whole_feet_and_inches() -> None:
    assert format_ft_in(8 + 4 / 12) == "8 ft 4 in"
    assert format_ft_in(3) == "3 ft 0 in"


def test_format_carries_twelve_inches_into_the_next_foot() -> None:
    # 0.99 ft is 11.88 in, which rounds to 12 in.
    assert format_ft_in(0.99) == "1 ft 0 in"
    assert format_ft_in(2.99) == "3 ft 0 in"


@pytest.mark.parametrize(
    ("feet", "expected"),
    [
        # Each value times 12 is exactly x.5 in binary floating point.
        (0.375, "0 ft 5 in"),  # 4.5 in; round() would give 4
        (0.875, "0 ft 11 in"),  # 10.5 in; round() would give 10
        (1.125, "1 ft 2 in"),  # 13.5 in
    ],
)
def test_format_rounds_half_an_inch_up(feet: float, expected: str) -> None:
    assert format_ft_in(feet) == expected


@pytest.mark.parametrize(
    ("inches", "expected"),
    [(0.5, "0 ft 1 in"), (4.5, "0 ft 5 in"), (11.5, "1 ft 0 in"), (100.5, "8 ft 5 in")],
)
def test_format_rounds_half_an_inch_up_after_converting_from_inches(
    inches: float, expected: str
) -> None:
    # x.5 / 12 is not exact in binary; the half must still round up.
    assert format_ft_in(in_to_ft(inches)) == expected


@pytest.mark.parametrize(
    ("feet", "expected"),
    [
        (math.nextafter(0.375, 0), "0 ft 4 in"),  # 4.499999999999999 in
        (0.37, "0 ft 4 in"),  # 4.44 in
        (math.nextafter(0.5 / 12, 0), "0 ft 0 in"),  # 0.4999999999999999 in
    ],
)
def test_format_rounds_below_half_an_inch_down(feet: float, expected: str) -> None:
    assert format_ft_in(feet) == expected


ALL_FUNCTIONS = [m_to_ft, ft_to_m, in_to_ft, ft_to_in, format_ft_in]


@pytest.mark.parametrize("func", ALL_FUNCTIONS)
def test_negative_input_raises_naming_the_value(func) -> None:
    with pytest.raises(ValueError, match=r"must not be negative, got -1\.5$"):
        func(-1.5)


@pytest.mark.parametrize("func", ALL_FUNCTIONS)
@pytest.mark.parametrize(
    ("value", "shown"), [(math.nan, "nan"), (math.inf, "inf"), (-math.inf, "-inf")]
)
def test_non_finite_input_raises_naming_the_value(func, value: float, shown: str) -> None:
    with pytest.raises(ValueError, match=rf"must be a finite number, got {shown}$"):
        func(value)
