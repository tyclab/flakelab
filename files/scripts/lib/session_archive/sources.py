"""Scan the redacted transcript copies under the state root for parent sessions to archive; never writes there."""

from dataclasses import dataclass
from datetime import UTC, datetime
import fnmatch
import hashlib
import json
import os
from pathlib import Path
import re

LIVE_SECONDS = 600
TAIL_LINES = 64
MAX_HOLDS = 3
# state-sync's names that are never state (files/scripts/nix-backup SYNC_ARTIFACT_GLOBS).
SYNC_ARTIFACT_GLOBS = (
    "*_Conflict", "*_Conflict.*", "*.sync-conflict-*", "*conflicted copy*", ".*.flakelab-tmp.*", ".syncthing.*.tmp",
    "~syncthing~*.tmp", ".stfolder", ".stversions", ".stignore", "@eaDir", ".DS_Store", "Thumbs.db", "desktop.ini",
)
UUID_TEXT = r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
SESSION_FILE = re.compile(rf"({UUID_TEXT})\.jsonl")
UUID_IN_NAME = re.compile(UUID_TEXT)
DATED = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T")
REMINDER = "<system-reminder"


class SourceError(RuntimeError):
    """The state root cannot be scanned; the message names no path."""


@dataclass(frozen=True)
class Candidate:
    uuid: str
    slug: str
    path: Path
    sha256: str | None
    last_entry: datetime | None
    reason: str


def is_sync_artifact(rel):
    """rel_path_is_sync_artifact in files/scripts/lib/state-sync.zsh: any artifact segment poisons the path."""
    return any(fnmatch.fnmatchcase(seg, glob) for seg in rel.split("/") if seg for glob in SYNC_ARTIFACT_GLOBS)


def tail_lines(path, count=TAIL_LINES, block=1 << 16):
    chunks, newlines = [], 0
    with path.open("rb") as fh:
        pos = fh.seek(0, os.SEEK_END)
        while pos > 0 and newlines <= count:
            step = min(block, pos)
            pos -= step
            fh.seek(pos)
            chunks.append(fh.read(step))
            newlines += chunks[-1].count(b"\n")
    return b"".join(reversed(chunks)).splitlines()[-count:]


def last_entry(path):
    """transcript_epoch in files/scripts/lib/state-sync.zsh: the last non-empty `timestamp` in the tail."""
    stamp = None
    for line in tail_lines(path):
        try:
            record = json.loads(line)
        except ValueError:
            continue
        if isinstance(record, dict) and isinstance(record.get("timestamp"), str) and record["timestamp"]:
            stamp = record["timestamp"]
    if stamp is None or not DATED.match(stamp):
        return None
    try:
        when = datetime.fromisoformat(stamp)
    except ValueError:
        return None
    return when if when.tzinfo else when.replace(tzinfo=UTC)


def operator_text(line):
    try:
        record = json.loads(line)
    except ValueError:
        return False
    if not isinstance(record, dict) or record.get("type") != "user":
        return False
    message = record.get("message")
    content = message.get("content") if isinstance(message, dict) else None
    if isinstance(content, str):
        texts = [content]
    elif isinstance(content, list):
        texts = [b.get("text") for b in content if isinstance(b, dict) and b.get("type") == "text"]
    else:
        return False
    return any(isinstance(t, str) and t.strip() and not t.lstrip().startswith(REMINDER) for t in texts)


def digest(path):
    """The file's SHA-256 and whether the operator wrote in it, in one read."""
    sha, spoke = hashlib.sha256(), False
    with path.open("rb") as fh:
        for line in fh:
            sha.update(line)
            spoke = spoke or (b'"user"' in line and operator_text(line))
    return sha.hexdigest(), spoke


def verdict(row, sha256):
    if row is None:
        return "eligible"
    if row["status"] == "held":
        return "held" if row["holds"] >= MAX_HOLDS else "eligible"
    if row["sha256"] != sha256:
        return "eligible"
    return "unchanged" if row["status"] == "done" else "review"


def judge(cfg, store, now, uuid, slug, path, stat):
    age = now.timestamp() - stat.st_mtime
    if age < LIVE_SECONDS:
        return Candidate(uuid, slug, path, None, None, "live")
    last = last_entry(path)
    # Unknown age falls back to the file's mtime, which is never earlier than its last record.
    if last is not None:
        age = now.timestamp() - last.timestamp()
    if age < cfg.quiet_days * 86400:
        return Candidate(uuid, slug, path, None, last, "quiet")
    sha256, spoke = digest(path)
    reason = verdict(store.session(uuid), sha256) if spoke else "no_operator_text"
    return Candidate(uuid, slug, path, sha256, last, reason)


def scan(cfg, store, now):
    """Every parent transcript of the configured projects, one per uuid (the largest copy), oldest entry first."""
    if cfg.state_root is None:
        raise SourceError("FLAKELAB_STATE_ROOT is not set")
    projects = cfg.state_root / "claude/projects"
    if not projects.is_dir():
        raise SourceError("the state root has no claude/projects directory")
    found, largest = [], {}
    for slug in cfg.projects:
        try:
            entries = sorted(os.scandir(projects / slug), key=lambda e: e.name)
        except (FileNotFoundError, NotADirectoryError):
            continue
        for entry in entries:
            if ".jsonl" not in entry.name or not entry.is_file():
                continue
            path = Path(entry.path)
            if is_sync_artifact(f"{slug}/{entry.name}"):
                named = UUID_IN_NAME.search(entry.name)
                found.append(Candidate(named.group() if named else entry.name, slug, path, None, None, "artifact"))
                continue
            session = SESSION_FILE.fullmatch(entry.name)
            if session is None:
                continue
            stat = entry.stat()
            best = largest.get(session[1])
            if best is None or stat.st_size > best[2].st_size:
                largest[session[1]] = (slug, path, stat)
    found += [judge(cfg, store, now, uuid, *copy) for uuid, copy in largest.items()]
    oldest = datetime.min.replace(tzinfo=UTC)
    return sorted(found, key=lambda c: (c.last_entry is None, c.last_entry or oldest, c.slug, c.uuid, c.path.name))
