import datetime as dt

from hsverify.simrun import seconds_since, slug


def test_state_time_uses_the_log_clock():
    stamp = "2026-09-26 02:47:25.977214-0500"
    logged = dt.datetime.strptime(stamp, "%Y-%m-%d %H:%M:%S.%f%z").timestamp()
    assert seconds_since(logged - 2.5, stamp, fallback=9.0) == 2.5


def test_unparseable_timestamp_falls_back_to_arrival_time():
    assert seconds_since(0.0, "", fallback=1.234) == 1.23


def test_slug_is_filename_safe():
    assert slug("origin/t3/ios-mvf") == "origin-t3-ios-mvf"
    assert slug("wall walk: gap!") == "wall-walk-gap"
