"""The archive copy of a transcript, `<root>/<slug>/<uuid>.<sha8>.jsonl.gz`, and the `.owner` marker that keeps a second
box out of the archive root and the libraries. A copy is written once and never replaced by other content."""

import contextlib
import gzip
import hashlib
import os
from pathlib import Path
from uuid import uuid4
import zlib

OWNER = ".owner"
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
