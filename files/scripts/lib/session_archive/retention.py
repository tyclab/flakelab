"""Retention (SESSION_ARCHIVE_RETENTION_DAYS): a done session whose last entry is older than the period loses its archive
copies and its state-root transcript, its card says so, and its row becomes pruned. Only a session the lane archived
goes, and only while every file matches its row; anything else is kept for the next run. A real run's last step."""

from datetime import UTC, datetime, timedelta
import hashlib
import os
import re
import zlib

from session_archive import archive, cards

ERROR = "prune_error"
BLOCK = 1 << 20
FAILURES = (OSError, EOFError, zlib.error, UnicodeError)


def last(row) -> datetime:
    """The row's last entry; without one its file's mtime, which is never earlier."""
    if not row["last_entry"]:
        return datetime.fromtimestamp(row["mtime"], UTC)
    when = datetime.fromisoformat(row["last_entry"])
    return when if when.tzinfo else when.replace(tzinfo=UTC)


def file_sha(path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as source:
        while chunk := source.read(BLOCK):
            digest.update(chunk)
    return digest.hexdigest()


def holds(path, sha256) -> bool:
    """Whether path is absent or a plain file of exactly those bytes; anything else is a newer version to archive."""
    return not os.path.lexists(path) or (path.is_file() and not path.is_symlink() and file_sha(path) == sha256)


def remove(path):
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass


def prune_one(cfg, db, row, now, listing) -> str:
    """pruned or kept. The card is retired before any file goes, so it never names a missing one; a card retired
    before is a prune an error cut short, whose archive copy may be gone already."""
    uuid, slug, sha = row["uuid"], row["slug"], row["sha256"]
    area, folder = cfg.areas.get(row["area"]), cfg.root / slug
    copy = folder / f"{uuid}.{sha[:8]}.jsonl.gz"
    source = cfg.state_root / "claude/projects" / slug / f"{uuid}.jsonl"
    # state-sync's push copies a local transcript whose state-root copy is missing straight back.
    if area is None or row["archive_path"] != str(copy) or os.path.lexists(cfg.local_projects / slug / source.name):
        return "kept"
    try:
        text = (area.library / f"session-{uuid}.md").read_text(encoding="utf-8")
    except FileNotFoundError:
        return "kept"
    retired = cards.retire(text, copy, now.date().isoformat(), cfg.retention_days)
    if retired is None:
        return "kept"
    card, before = retired
    if (not before or os.path.lexists(copy)) and not (copy.is_file() and archive.unpacked_sha(copy) == sha):
        return "kept"
    if not holds(source, sha):
        return "kept"
    _, card_hash, _ = cards.write(area.library, uuid, card)
    if slug not in listing:
        listing[slug] = sorted(os.listdir(folder)) if folder.is_dir() else []
    # Every copy of the session, the versions it grew past included: `<uuid>.<sha8>.jsonl.gz`, as archive.copy names.
    named = re.compile(rf"{re.escape(uuid)}\.[0-9a-f]{{8}}\.jsonl\.gz")
    for name in listing[slug]:
        if named.fullmatch(name):
            remove(folder / name)
    if not holds(source, sha):
        return "kept"
    remove(source)
    return "pruned" if db.mark_pruned(uuid, sha, card_hash) else "kept"


def prune(cfg, db, now, counts) -> list[str]:
    """Each done session past the period, pruned or kept, into counts; the kind of each error that stopped one (never a
    path or transcript text). Either way the next run tries again."""
    cutoff, errors, listing = now - timedelta(days=cfg.retention_days), [], {}
    for row in db.by_status("done"):
        if last(row) >= cutoff:
            continue
        try:
            counts[prune_one(cfg, db, row, now, listing)] += 1
        except FAILURES as error:
            errors.append(type(error).__name__)
    counts["prune_errors"] += len(errors)
    return errors
