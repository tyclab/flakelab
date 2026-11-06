"""The archive copy of a transcript, `<root>/<slug>/<uuid>.<sha8>.jsonl.gz`, the archive of its `<uuid>/` folder of
subagent transcripts and tool results beside it, `<uuid>.<sha8>.subagents.tar.gz`, and the `.owner` marker that keeps a
second box out of the archive root and the libraries. A copy is written once and never replaced by other content."""

import contextlib
import gzip
import hashlib
import os
from pathlib import Path
import stat
import tarfile
from uuid import uuid4
import zlib

OWNER = ".owner"
SUBAGENTS = ".subagents.tar.gz"
MACHINE_ID = "/etc/machine-id"
BLOCK = 1 << 20


class ArchiveError(RuntimeError):
    """The archive copy cannot be made; the message names no path."""


def machine_id(env) -> str:
    """SESSION_ARCHIVE_MACHINE_ID (tests) or /etc/machine-id, stripped."""
    try:
        found = env.get("SESSION_ARCHIVE_MACHINE_ID") or Path(MACHINE_ID).read_text().strip()
    except OSError:
        found = ""
    if not found:
        raise ArchiveError(f"no machine id in {MACHINE_ID} to mark the archive root and libraries with")
    return found


def owner(folder) -> str | None:
    """The machine id in folder's .owner; None when the folder or marker is absent, unreadable or empty."""
    try:
        return (Path(folder) / OWNER).read_text().strip() or None
    except OSError:
        return None


def check_owner(folder, machine_id) -> bool:
    """False when folder's .owner names another machine; claims a folder that has none. A folder that is absent or
    cannot take the marker stays unclaimed: the run holds whatever it would write there."""
    found = owner(folder)
    if found is None:
        try:
            with (Path(folder) / OWNER).open("x") as marker:
                marker.write(f"{machine_id}\n")
            return True
        except FileExistsError:
            found = owner(folder)
        except OSError:
            return True
    return found in (None, machine_id)


def unpacked_sha(path) -> str:
    digest = hashlib.sha256()
    with gzip.open(path, "rb") as packed:
        while chunk := packed.read(BLOCK):
            digest.update(chunk)
    return digest.hexdigest()


def file_sha(path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as source:
        while chunk := source.read(BLOCK):
            digest.update(chunk)
    return digest.hexdigest()


def members(folder) -> list[tuple[str, os.stat_result]]:
    """(name relative to folder, lstat) of everything under it, in name order. Any listing error raises; an entry that
    is neither a file nor a folder (a link, a socket) is an ArchiveError."""

    def failed(error):
        raise error

    found = []
    for top, folders, files in os.walk(folder, onerror=failed):
        for name in folders + files:
            path = Path(top) / name
            info = os.lstat(path)
            if not (stat.S_ISDIR(info.st_mode) or stat.S_ISREG(info.st_mode)):
                raise ArchiveError("the subagents folder holds an entry that is neither a file nor a folder")
            found.append((path.relative_to(folder).as_posix(), info))
    return sorted(found, key=lambda member: member[0])


def pack_folder(folder, raw):
    """folder as a gzipped tar into raw: names relative to it in name order, each entry's mode and mtime, no owner and
    a gzip header without a timestamp, so the same folder packs to the same bytes."""
    with gzip.GzipFile(filename="", mode="wb", compresslevel=6, fileobj=raw, mtime=0) as packed, \
            tarfile.open(fileobj=packed, mode="w", format=tarfile.PAX_FORMAT) as tar:
        for name, info in members(folder):
            entry = tarfile.TarInfo(name)
            entry.mode, entry.mtime, entry.uid, entry.gid = stat.S_IMODE(info.st_mode), info.st_mtime, 0, 0
            if stat.S_ISDIR(info.st_mode):
                entry.type = tarfile.DIRTYPE
                tar.addfile(entry)
                continue
            entry.size = info.st_size
            with open(Path(folder) / name, "rb") as source:
                tar.addfile(entry, source)


def subagents(root, slug, uuid, sha256, folder) -> tuple[tuple[Path, str, int], bool] | None:
    """((path, SHA-256, bytes), created) of folder packed beside the transcript's copy as
    `<uuid>.<sha8>.subagents.tar.gz`; None when there is no folder. An existing archive of the same bytes is kept, one
    of other bytes (the folder changed while the transcript did not) replaced by the new one."""
    try:
        info = os.lstat(folder)
    except FileNotFoundError:
        return None
    except OSError as error:
        raise ArchiveError(f"the subagents folder cannot be read: {error.strerror or type(error).__name__}") from None
    if not stat.S_ISDIR(info.st_mode):
        raise ArchiveError("the subagents folder is not a folder")
    target = Path(root) / slug / f"{uuid}.{sha256[:8]}{SUBAGENTS}"
    temp = target.with_name(f".{target.name}.{uuid4().hex[:8]}.tmp")
    try:
        target.parent.mkdir(exist_ok=True)
        with open(temp, "xb") as raw:
            pack_folder(folder, raw)
            raw.flush()
            os.fsync(raw.fileno())
        digest, size = file_sha(temp), temp.stat().st_size
        if target.exists() and file_sha(target) == digest:
            return (target, digest, size), False
        os.replace(temp, target)
        directory = os.open(target.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    except (OSError, tarfile.TarError) as error:
        raise ArchiveError(f"the subagents archive failed: {getattr(error, 'strerror', None) or type(error).__name__}") \
            from None
    finally:
        # Only this call's own temp file, left behind when the write failed or the archive was there already.
        with contextlib.suppress(OSError):
            temp.unlink()
    return (target, digest, size), True


def pack(src, temp) -> str:
    """src gzipped into the new file temp, synced; the SHA-256 of the bytes read."""
    digest = hashlib.sha256()
    with open(temp, "xb") as raw:
        with gzip.GzipFile(filename="", mode="wb", compresslevel=6, fileobj=raw, mtime=0) as packed, \
                open(src, "rb") as source:
            while chunk := source.read(BLOCK):
                digest.update(chunk)
                packed.write(chunk)
        raw.flush()
        os.fsync(raw.fileno())
    return digest.hexdigest()


def copy(root, slug, uuid, src, sha256) -> tuple[Path, bool]:
    """(path, created) of src's archive copy, whose SHA-256 the scan took: the existing file when it holds those bytes,
    else a new one written under a temp name and renamed into place."""
    if root is None:
        raise ArchiveError("no archive root is configured (SESSION_ARCHIVE_ROOT)")
    if not Path(root).is_dir():
        raise ArchiveError("the archive root is unreachable")
    folder = Path(root) / slug
    target = folder / f"{uuid}.{sha256[:8]}.jsonl.gz"
    temp = folder / f".{target.name}.{uuid4().hex[:8]}.tmp"
    try:
        folder.mkdir(exist_ok=True)
        if target.exists():
            if unpacked_sha(target) != sha256:
                raise ArchiveError("an archive copy of other content holds this copy's name")
            return target, False
        if pack(src, temp) != sha256:
            raise ArchiveError("the transcript changed after the scan")
        os.replace(temp, target)
        directory = os.open(folder, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    except (OSError, EOFError, zlib.error) as error:
        raise ArchiveError(f"the archive copy failed: {getattr(error, 'strerror', None) or type(error).__name__}") \
            from None
    finally:
        # Only this call's own temp file, left behind when the write or the rename failed.
        with contextlib.suppress(OSError):
            temp.unlink()
    return target, True
