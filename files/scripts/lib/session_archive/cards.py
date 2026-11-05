"""Summary cards: the markdown of one session's card and its atomic write into an area's library; never deletes a card.

An item renders as `- <text> (unverified) @L<a>,@L<b>`, the note only when the citation check did not verify it, then an
open end's `as of <date>, tracked in <ref>` line and one `> "<quote>"` line per quote line, indented under the bullet.
"""

from dataclasses import dataclass
import hashlib
import os
from pathlib import Path
import tempfile

RECIPE = "session-archive-v1"
SECTIONS = (("why", "Why"), ("when", "When"), ("how", "How"), ("outcome", "Outcome"), ("open_ends", "Open ends"),
            ("continue", "What an agent needs to continue"))
POINTER = "## Pointer"
EXTRACTED = "Extracted: "
NONE = "None."


@dataclass(frozen=True)
class CardMeta:
    uuid: str
    slug: str
    area: str
    archive_path: str | Path
    sha256: str
    bytes: int
    local_path: str | Path
    model_id: str
    effort: str
    extracted: str


def one_line(text) -> str:
    return " ".join(text.split())


def bullet(item) -> list[str]:
    anchors = ",".join(f"@L{line}" for line in item["anchors"])
    head = [one_line(item["text"]), "" if item.get("verified") else "(unverified)", anchors]
    lines = ["- " + " ".join(part for part in head if part)]
    if "as_of" in item:
        lines.append(f"  as of {one_line(item['as_of'])}, tracked in {one_line(item['tracked_in'])}")
    for quote in item["quotes"]:
        lines.extend(f"  > {part}" for part in f'"{quote}"'.splitlines())
    return lines


def pointer(meta) -> list[str]:
    archive = str(meta.archive_path)
    fetch = "'" + archive.replace("'", "'\\''") + "'"
    return [f"Archive: {archive}", f"SHA-256: {meta.sha256}", f"Bytes: {meta.bytes}", f"Fetch: zcat {fetch}",
            f"Local (until cleanup): {meta.local_path}", f"Project: {meta.slug}", f"Area: {meta.area}",
            f"Recipe: {RECIPE}", f"Model: {meta.model_id}/{meta.effort}", f"{EXTRACTED}{meta.extracted}"]


def render(meta: CardMeta, summary) -> str:
    lines = [f"# Session {meta.uuid}", "", "## What", "", one_line(summary["what"]) or NONE, ""]
    for name, heading in SECTIONS:
        lines += [f"## {heading}", "", *([line for item in summary[name] for line in bullet(item)] or [NONE]), ""]
    return "\n".join([*lines, POINTER, "", *pointer(meta)]) + "\n"


def content_hash(text) -> str:
    """SHA-256 of a card without its pointer's Extracted line: a re-run that changes nothing else hashes the same."""
    head, mark, tail = text.rpartition(f"\n{POINTER}\n")
    tail = "".join(line for line in tail.splitlines(keepends=True) if not line.startswith(EXTRACTED))
    return hashlib.sha256((head + mark + tail).encode()).hexdigest()


def umask() -> int:
    mask = os.umask(0o077)
    os.umask(mask)
    return mask


def write(library, uuid, text) -> tuple[Path, str, bool]:
    """(path, content hash, written): session-<uuid>.md in library, replaced only when its content hash changed. The
    library must exist: a missing one is an unmounted share, not a folder to create."""
    path = Path(library) / f"session-{uuid}.md"
    digest = content_hash(text)
    try:
        if content_hash(path.read_bytes().decode(errors="replace")) == digest:
            return path, digest, False
    except FileNotFoundError:
        pass
    fd, temp = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            stream.write(text)
            stream.flush()
            os.fchmod(stream.fileno(), 0o666 & ~umask())
            os.fsync(stream.fileno())
        os.replace(temp, path)
    finally:
        # Only this call's own temp file, left behind when the write or the rename failed.
        if os.path.exists(temp):
            os.unlink(temp)
    return path, digest, True
