"""Retention (SESSION_ARCHIVE_RETENTION_DAYS), a full run's last step. A done session whose last entry is older than the
period loses every copy of its transcript and of its <uuid>/ folder in the state root, under any slug, and every archive
copy and subagents archive of it; its card's pointer says so and its row becomes pruned. A pruned session whose
transcript comes back with the same bytes loses it again. Only what the archive pair proves goes: nothing while this
box still holds a copy, nothing that cannot be read (only a missing file counts as absent), and nothing on a dry run."""

from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
import gzip
import hashlib
import os
from pathlib import Path
import re
import shutil
import stat
import tarfile
import zlib

from session_archive import archive, cards, sources, store
from session_archive.archive import file_sha

ERROR = "prune_error"
BLOCK = 1 << 20
FAILURES = (OSError, EOFError, zlib.error, UnicodeError, ValueError, tarfile.TarError, archive.ArchiveError)
FOLDER = re.compile(sources.UUID_TEXT)
PAIR = re.compile(rf"({sources.UUID_TEXT})\.[0-9a-f]{{8}}\.(?:jsonl|subagents\.tar)\.gz")


@dataclass(frozen=True)
class Found:
    """By uuid, from one listing of each tree at the step's start."""
    transcripts: dict  # the state root's <slug>/<uuid>.jsonl
    folders: dict  # the state root's <slug>/<uuid>/
    pairs: dict  # the archive root's <slug>/<uuid>.<sha8>.jsonl.gz and .subagents.tar.gz
    local: set  # this box's ~/.claude/projects/<slug>/<uuid>.jsonl, and <uuid>/ with a file in it


def column(row, name):
    """A version 4 column, None in a version 3 row a dry run reads."""
    return row[name] if name in row.keys() else None


def last(row) -> datetime:
    """The row's last entry; without one its file's mtime, which is never earlier."""
    if not row["last_entry"]:
        return datetime.fromtimestamp(row["mtime"], UTC)
    when = datetime.fromisoformat(row["last_entry"])
    return when if when.tzinfo else when.replace(tzinfo=UTC)


def lstat(path):
    """path's lstat, None once it is gone; any other error raises."""
    try:
        return os.lstat(path)
    except FileNotFoundError:
        return None


def raising(error):
    raise error


def listing(top) -> list:
    """(name, path) of each entry in each folder under top that is no sync artifact; an absent top is empty."""
    try:
        with os.scandir(top) as entries:
            folders = sorted((entry for entry in entries if not sources.is_sync_artifact(entry.name)
                              and entry.is_dir()), key=lambda entry: entry.name)
    except FileNotFoundError:
        return []
    found = []
    for folder in folders:
        try:
            with os.scandir(folder.path) as entries:
                found.extend((entry.name, Path(entry.path)) for entry in entries)
        except FileNotFoundError:
            continue
    return found


def holds_files(path) -> bool:
    """Whether path is anything but a tree of folders: what state-sync could push back from it."""
    info = os.lstat(path)
    if not stat.S_ISDIR(info.st_mode):
        return True
    for top, folders, files in os.walk(path, onerror=raising):
        if files or any(os.path.islink(os.path.join(top, name)) for name in folders):
            return True
    return False


def find(cfg) -> Found:
    transcripts, folders, pairs, local = {}, {}, {}, set()
    for name, path in listing(cfg.state_root / "claude/projects"):
        if named := sources.SESSION_FILE.fullmatch(name):
            transcripts.setdefault(named[1], []).append(path)
        elif FOLDER.fullmatch(name):
            folders.setdefault(name, []).append(path)
    for name, path in listing(cfg.local_projects):
        if named := sources.SESSION_FILE.fullmatch(name):
            local.add(named[1])
        elif FOLDER.fullmatch(name) and holds_files(path):
            local.add(name)
    for name, path in listing(cfg.root):
        if named := PAIR.fullmatch(name):
            pairs.setdefault(named[1], []).append(path)
    return Found(transcripts, folders, pairs, local)


def unpacked(path, lengths) -> tuple[str, dict]:
    """The SHA-256 of a gzip copy's unpacked bytes, and of their first n bytes for each n in lengths it reaches."""
    digest, prefixes, done = hashlib.sha256(), {}, 0
    wanted = sorted(set(lengths))
    with gzip.open(path, "rb") as packed:
        while True:
            chunk = packed.read(BLOCK)
            while wanted and wanted[0] <= done + len(chunk):
                head = digest.copy()
                head.update(chunk[:wanted[0] - done])
                prefixes[wanted.pop(0)] = head.hexdigest()
            if not chunk:
                return digest.hexdigest(), prefixes
            digest.update(chunk)
            done += len(chunk)


def packed_members(path) -> dict:
    """name -> SHA-256 of each file in a subagents archive, None for a folder."""
    found = {}
    with tarfile.open(path, "r:gz") as tar:
        for member in tar:
            if member.isdir():
                found[member.name] = None
                continue
            if not member.isfile():
                raise tarfile.TarError("the subagents archive holds a member that is neither a file nor a folder")
            digest = hashlib.sha256()
            with tar.extractfile(member) as data:
                while chunk := data.read(BLOCK):
                    digest.update(chunk)
            found[member.name] = digest.hexdigest()
    return found


def shape(folder) -> list:
    return [(name, info.st_mode, info.st_size, info.st_mtime_ns) for name, info in archive.members(folder)]


def proven(folder, packed) -> list | None:
    """The folder's shape when each file in it is in the subagents archive with the same bytes, else None."""
    try:
        entries = archive.members(folder)
    except archive.ArchiveError:
        return None
    for name, info in entries:
        if stat.S_ISREG(info.st_mode) and packed.get(name) != file_sha(os.path.join(folder, name)):
            return None
    return [(name, info.st_mode, info.st_size, info.st_mtime_ns) for name, info in entries]


def folder_digests(folder) -> dict:
    """name -> SHA-256 of each file under folder, None for a folder: what packing it would archive."""
    return {name: file_sha(os.path.join(folder, name)) if stat.S_ISREG(info.st_mode) else None
            for name, info in archive.members(folder)}


def backfill(cfg, db, row, found, dry_run) -> str | None:
    """subagents_backfilled when a done session the lane took before it packed folders gets its subagents archive for
    the recorded sha8, the row its SHA-256 and size and the card its Subagents line, with no model call; None when it
    has one, its <uuid>/ folder beside its transcript is absent, or its copy or card is not the lane's."""
    uuid, slug, sha = row["uuid"], row["slug"], row["sha256"]
    folder = cfg.state_root / "claude/projects" / slug / uuid
    if column(row, "subagents_sha256") or folder not in found.folders.get(uuid, []):
        return None
    area, copy = cfg.areas.get(row["area"]), cfg.root / slug / f"{uuid}.{sha[:8]}.jsonl.gz"
    if area is None or row["archive_path"] != str(copy):
        return None
    try:
        text = (area.library / f"session-{uuid}.md").read_text(encoding="utf-8")
    except FileNotFoundError:
        return None
    planned = copy.with_name(f"{uuid}.{sha[:8]}{archive.SUBAGENTS}")
    # Everything is checked before anything is packed: a card that cannot take the line leaves no archive behind.
    info = lstat(folder)
    fits = (cards.with_subagents(text, copy, uuid, (planned, "", 0)) is not None
            or f"\n{cards.SUBAGENTS}{planned}, " in text)
    if info is None or not stat.S_ISDIR(info.st_mode) or not fits:
        return None
    if dry_run:
        return "subagents_backfilled"
    packed = archive.subagents(cfg.root, slug, uuid, sha, folder)
    card = packed and cards.with_subagents(text, copy, uuid, packed[0])
    if not card:
        return None
    _, card_hash, _ = cards.write(area.library, uuid, card)
    _, digest, size = packed[0]
    return "subagents_backfilled" if db.record_subagents(uuid, sha, digest, size, card_hash) else None


def remove(path):
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass


def prune_done(cfg, db, row, now, found, dry_run) -> str:
    """pruned or kept. The card is retired first, so it never names a missing file, then the state root's copies go
    and the archive pair last, so a prune an error cuts short (its card retired) is proven again by what is left."""
    uuid, slug, sha = row["uuid"], row["slug"], row["sha256"]
    area, copy = cfg.areas.get(row["area"]), cfg.root / slug / f"{uuid}.{sha[:8]}.jsonl.gz"
    recorded = column(row, "subagents_sha256"), column(row, "subagents_bytes")
    tar = copy.with_name(f"{uuid}.{sha[:8]}{archive.SUBAGENTS}") if recorded[0] else None
    transcripts, folders = found.transcripts.get(uuid, []), found.folders.get(uuid, [])
    # A dry run counts what the back-fill before it would make provable: its archive packs the folder beside the copy.
    pending = dry_run and tar is None and backfill(cfg, db, row, found, True) is not None
    # A <uuid> that is a link or a file is no folder the archive can prove; refused before the card is touched.
    for folder in folders:
        info = lstat(folder)
        if info is not None and not stat.S_ISDIR(info.st_mode):
            return "kept"
    # state-sync pushes back a transcript or side file this box still holds.
    if area is None or row["archive_path"] != str(copy) or uuid in found.local or (folders and tar is None
                                                                                 and not pending):
        return "kept"
    try:
        text = (area.library / f"session-{uuid}.md").read_text(encoding="utf-8")
    except FileNotFoundError:
        return "kept"
    retired = cards.retire(text, copy, now.date().isoformat(), cfg.retention_days, tar)
    if retired is None:
        return "kept"
    card, before = retired
    sizes = {}
    for path in transcripts:
        info = lstat(path)
        if info is not None and (not stat.S_ISREG(info.st_mode) or info.st_size > row["size"]):
            return "kept"  # a link, or a longer version for the scan to archive first
        if info is not None:
            sizes[path] = info.st_size
    prefixes, members = {}, None
    if not before or lstat(copy) is not None:
        info = lstat(copy)
        if info is None or not stat.S_ISREG(info.st_mode):
            return "kept"
        full, prefixes = unpacked(copy, sizes.values())
        if full != sha:
            return "kept"
    if tar is not None and (not before or lstat(tar) is not None):
        info = lstat(tar)
        if info is None or not stat.S_ISREG(info.st_mode) or info.st_size != recorded[1] or file_sha(tar) != recorded[0]:
            return "kept"
        members = packed_members(tar)
    if pending:
        members = folder_digests(cfg.state_root / "claude/projects" / slug / uuid)
    if folders and members is None:
        return "kept"
    shapes = {}
    for folder in folders:
        shapes[folder] = proven(folder, members)
        if shapes[folder] is None:
            return "kept"
    digests = {}
    for path, size in sizes.items():
        got = file_sha(path)
        if got != sha and got != prefixes.get(size):
            return "kept"  # neither this version nor a prefix of it
        digests[path] = got
    if dry_run:
        return "pruned"
    _, card_hash, _ = cards.write(area.library, uuid, card)
    for path, got in digests.items():
        if lstat(path) is not None and file_sha(path) != got:
            return "kept"
        remove(path)
    for folder, was in shapes.items():
        if lstat(folder) is None:
            continue
        if shape(folder) != was:
            return "kept"  # it changed since it was proven
        shutil.rmtree(folder)
    for path in {copy, *([tar] if tar else []), *found.pairs.get(uuid, [])}:
        remove(path)
    return "pruned" if db.mark_pruned(uuid, sha, card_hash) else "kept"


def prune_returned(row, found, dry_run) -> str | None:
    """repruned when the pruned session's transcript is back with its bytes and this box holds no copy; kept when it is
    back otherwise; None when nothing came back."""
    uuid, sha = row["uuid"], row["sha256"]
    transcripts = found.transcripts.get(uuid, [])
    if not transcripts:
        return None
    if uuid in found.local:
        return "kept"
    for path in transcripts:
        info = lstat(path)
        if info is not None and (not stat.S_ISREG(info.st_mode) or file_sha(path) != sha):
            return "kept"
    if not dry_run:
        for path in transcripts:
            if lstat(path) is not None and file_sha(path) == sha:
                remove(path)
    return "repruned"


def prune(cfg, db, now, counts, dry_run=False) -> list[str]:
    """The back-fill of every done session without a subagents archive, then each done or pruned session past the
    period, into counts; the kind of each error that stopped one (never a path or transcript text), which the next run
    retries. A tree that cannot be listed stops the whole step."""
    cutoff, errors = now - timedelta(days=cfg.retention_days), []
    try:
        found = find(cfg)
    except FAILURES as error:
        counts["prune_errors"] += 1
        return [type(error).__name__]
    for row in db.by_status("done"):
        try:
            if backfill(cfg, db, row, found, dry_run):
                counts["subagents_backfilled"] += 1
        except FAILURES as error:
            errors.append(type(error).__name__)
    for row in [*db.by_status("done"), *db.by_status(store.PRUNED)]:
        try:
            if last(row) >= cutoff:
                continue
            outcome = (prune_done(cfg, db, row, now, found, dry_run) if row["status"] == "done"
                       else prune_returned(row, found, dry_run))
        except FAILURES as error:
            errors.append(type(error).__name__)
            continue
        if outcome:
            counts[outcome] += 1
    counts["prune_errors"] += len(errors)
    return errors
