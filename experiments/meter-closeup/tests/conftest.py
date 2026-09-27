import pytest

from meter_eval import match


@pytest.fixture(autouse=True)
def test_key(monkeypatch):
    """Tests digest with a fixed key, never the real one."""
    monkeypatch.setenv("METER_HMAC_KEY", "00" * 32)
    match.key.cache_clear()
    yield
    match.key.cache_clear()
