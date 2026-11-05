"""Settings of `flakelab session-archive`, read from the SESSION_ARCHIVE_* variables its wrapper exports."""

from dataclasses import dataclass
import json
import math
from pathlib import Path

RESERVED_AREA = "unclear"


class ConfigError(ValueError):
    """A setting the lane cannot use; the message starts with the variable's name."""


@dataclass(frozen=True)
class Area:
    name: str
    description: str
    library: Path
    projects: list[str]


@dataclass(frozen=True)
class Config:
    root: Path | None
    areas: dict[str, Area]
    projects: list[str]
    model: str
    effort: str
    quiet_days: int
    run_cap_usd: float
    run_sessions: int
    state_dir: Path
    state_root: Path | None
    retention_days: int | None
    local_projects: Path


def absolute(env, name):
    raw = env.get(name, "")
    if not raw:
        return None
    if not raw.startswith("/"):
        raise ConfigError(f"{name} is not an absolute path")
    return Path(raw)


def number(env, name, kind, default, least):
    raw = env.get(name, "").strip()
    if not raw:
        return default
    try:
        value = kind(raw)
    except ValueError:
        raise ConfigError(f"{name} is not a number: {raw!r}") from None
    if not (math.isfinite(value) and value >= least):
        raise ConfigError(f"{name} must be {least} or more: {raw!r}")
    return value


def area(name, spec):
    def bad(why):
        return ConfigError(f"SESSION_ARCHIVE_AREAS: area {name!r} {why}")

    if name == RESERVED_AREA:
        raise bad("is reserved for sessions that fit no area")
    if not isinstance(spec, dict):
        raise bad("is not an object")
    description, library, projects = spec.get("description"), spec.get("library"), spec.get("projects")
    if not isinstance(description, str):
        raise bad("needs a description string")
    if not (isinstance(library, str) and library.startswith("/")):
        raise bad("needs an absolute library path")
    # A slug is one directory name under the state root's claude/projects; never a path out of it.
    if not (isinstance(projects, list)
            and all(isinstance(p, str) and p not in ("", ".", "..") and "/" not in p for p in projects)):
        raise bad("needs projects as a list of project directory names")
    return Area(name, description, Path(library), list(projects))


def areas(raw):
    try:
        data = json.loads(raw) if raw.strip() else {}
    except ValueError:
        raise ConfigError("SESSION_ARCHIVE_AREAS is not JSON") from None
    if not isinstance(data, dict):
        raise ConfigError("SESSION_ARCHIVE_AREAS is not a JSON object")
    return {name: area(name, spec) for name, spec in data.items()}


def load(env) -> Config:
    configured = areas(env.get("SESSION_ARCHIVE_AREAS", ""))
    home = Path(env.get("HOME") or Path.home())
    state_home = env.get("XDG_STATE_HOME") or str(home / ".local/state")
    return Config(
        root=absolute(env, "SESSION_ARCHIVE_ROOT"),
        areas=configured,
        projects=sorted({slug for a in configured.values() for slug in a.projects}),
        model=env.get("SESSION_ARCHIVE_MODEL") or "claude-haiku-5-5",
        effort=env.get("SESSION_ARCHIVE_EFFORT") or "low",
        quiet_days=number(env, "SESSION_ARCHIVE_QUIET_DAYS", int, 3, 0),
        run_cap_usd=number(env, "SESSION_ARCHIVE_RUN_CAP_USD", float, 2.0, 0),
        run_sessions=number(env, "SESSION_ARCHIVE_RUN_SESSIONS", int, 20, 1),
        state_dir=Path(state_home) / "flakelab/session-archive",
        state_root=absolute(env, "FLAKELAB_STATE_ROOT"),
        retention_days=number(env, "SESSION_ARCHIVE_RETENTION_DAYS", int, None, 1),
        # This box's own transcripts, which state-sync pushes into the state root (its TX_HOME).
        local_projects=home / ".claude/projects",
    )
