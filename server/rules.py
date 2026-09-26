"""Load rules.yaml, merge the private override over it, and validate the result.

Every threshold the solver compares against lives in the rules file. A missing or misspelled key is
a startup error naming the key, never a silent default.
"""

import copy
import hashlib
import json
import os
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Literal

import yaml
from pydantic import BaseModel, ConfigDict, Field

SERVER_DIR = Path(__file__).resolve().parent
PUBLIC_RULES = SERVER_DIR / "rules.yaml"
PRIVATE_RULES_ENV = "HOUSESCAN_PRIVATE_RULES"
DEFAULT_PRIVATE_RULES = SERVER_DIR.parent / "private" / "rules.yaml"

Effect = Literal["fail", "review", "detour", "allow"]
ObjectType = Literal[
    "window", "door", "garage_door", "ac", "gas_meter", "elec_box", "vent", "downspout", "pool"
]
GroundType = Literal["drive", "concrete", "gravel", "lawn", "mulch", "deck"]


class _Strict(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)


class Value(_Strict):
    value: float = Field(ge=0, allow_inf_nan=False)
    source: str = Field(min_length=1)
    placeholder: bool = False


class Policy(_Strict):
    id: str | None
    version: str | None
    auto_approve: bool
    allow_reject: bool


class Battery(_Strict):
    width_ft: Value
    depth_ft: Value
    height_ft: Value


class Errors(_Strict):
    tap_ft: Value
    vlm_ft: Value
    mesh_ft: Value
    tape_ft: Value
    wall_ft: Value
    meter_ft: Value
    drift_per_ft: Value


class Sweep(_Strict):
    step_ft: Value
    wall_join_ft: Value
    meter_to_wall_max_ft: Value


class Clearances(_Strict):
    gas_ft: Value
    ac_ft: Value
    opening_ft: Value
    drive_ft: Value
    pool_ft: Value
    wall_equipment_ft: Value


class Openings(_Strict):
    types: list[ObjectType]
    exempt_fixed_windows: bool
    exempt_bottom_above_ft: float | None


class WallEquipment(_Strict):
    types: list[ObjectType]


class Facing(_Strict):
    min_ft: Value
    measured_from: Literal["battery_front", "wall"]


class Headroom(_Strict):
    min_ft: Value


class MeterWorkingSpace(_Strict):
    width_ft: Value
    depth_ft: Value


class Ground(_Strict):
    allowed: list[GroundType]
    drivable: list[GroundType]
    source: str = Field(min_length=1)
    placeholder: bool


class Route(_Strict):
    max_ft: Value
    confident_reach_ft: Value
    height_ft: Value
    corner_allowance_ft: Value
    crossing: dict[ObjectType, Effect]


class Rules(_Strict):
    policy: Policy
    battery: Battery
    errors: Errors
    sweep: Sweep
    clearances: Clearances
    openings: Openings
    wall_equipment: WallEquipment
    facing: Facing
    headroom: Headroom
    meter_working_space: MeterWorkingSpace
    ground: Ground
    route: Route


@dataclass(frozen=True)
class LoadedRules:
    rules: Rules
    sources: tuple[str, ...]
    sha256: str
    # Dotted keys the private file overrides. Answers withhold their source text.
    private_keys: frozenset[str] = frozenset()


def deep_merge(base: dict[str, Any], override: dict[str, Any]) -> dict[str, Any]:
    """Mappings merge key by key; any other override value replaces the base value."""
    merged = copy.deepcopy(base)
    for key, value in override.items():
        if isinstance(value, dict) and isinstance(merged.get(key), dict):
            merged[key] = deep_merge(merged[key], value)
        else:
            merged[key] = copy.deepcopy(value)
    return merged


def _read_yaml(path: Path) -> dict[str, Any]:
    data = yaml.safe_load(path.read_text())
    if not isinstance(data, dict):
        raise ValueError(f"{path}: expected a mapping at the top level")
    return data


def rules_from_dict(
    data: dict[str, Any],
    sources: tuple[str, ...] = ("public",),
    private_keys: frozenset[str] = frozenset(),
) -> LoadedRules:
    rules = Rules.model_validate(data)
    canonical = json.dumps(rules.model_dump(mode="json"), sort_keys=True, separators=(",", ":"))
    return LoadedRules(rules, sources, hashlib.sha256(canonical.encode()).hexdigest(), private_keys)


def overridden_keys(public: dict[str, Any], private: dict[str, Any], path: str = "") -> set[str]:
    """Dotted keys the private file sets. A private threshold must carry its own source: merged
    over the public one, it would otherwise be shown with the public citation."""
    keys: set[str] = set()
    for key, value in private.items():
        dotted = f"{path}{key}"
        base = public.get(key)
        if isinstance(value, dict) and isinstance(base, dict):
            if "value" in base and "source" in base and "source" not in value:
                raise ValueError(
                    f"private rules: {dotted} overrides a cited value without its own source"
                )
            if "value" in base:
                keys.add(dotted)
            else:
                keys |= overridden_keys(base, value, f"{dotted}.")
        else:
            keys.add(dotted)
    return keys


def public_rules_dict() -> dict[str, Any]:
    return _read_yaml(PUBLIC_RULES)


def load_rules(private_path: Path | None = None) -> LoadedRules:
    """Public rules, with the private file merged over them when it exists."""
    data = public_rules_dict()
    sources: tuple[str, ...] = ("public",)
    if private_path is None:
        env = os.environ.get(PRIVATE_RULES_ENV)
        private_path = Path(env) if env else DEFAULT_PRIVATE_RULES
        if env and not private_path.is_file():
            raise FileNotFoundError(f"{PRIVATE_RULES_ENV}={env} does not name a file")
    private_keys: frozenset[str] = frozenset()
    if private_path.is_file():
        private = _read_yaml(private_path)
        private_keys = frozenset(overridden_keys(data, private))
        data = deep_merge(data, private)
        sources = ("public", "private")
    return rules_from_dict(data, sources, private_keys)
