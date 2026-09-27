import pytest

import api
from rules import public_rules_dict, rules_from_dict


@pytest.fixture(autouse=True)
def public_api(monkeypatch: pytest.MonkeyPatch) -> None:
    """API tests run against the public rules, whatever private file this checkout holds, and
    without an API key; tests of the private mode set both themselves."""
    monkeypatch.setattr(api, "LOADED", rules_from_dict(public_rules_dict()))
    monkeypatch.setattr(api, "API_KEY", None)
