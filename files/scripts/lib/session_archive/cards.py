"""Summary cards: the markdown of one session's card, its atomic write into an area's library, and its pointer retired
once retention removes the files it names; never deletes a card.

An item renders as `- <text> (unverified) @L<a>,@L<b>`, the note only when the citation check did not verify it, then an
open end's `as of <date>, tracked in <ref>` line (an empty part, or a ref such as `not tracked`, left out) and one
`> "<quote>"` line per quote line, indented under the bullet. The model's `what` and item text sit on one line with a
leading Markdown block marker escaped, so they cannot open a heading, list, quote, fence, table or HTML block.
"""

from dataclasses import dataclass
import hashlib
import os
from pathlib import Path
import re
import tempfile

RECIPE = "session-archive-v1"
SECTIONS = (("why", "Why"), ("when", "When"), ("how", "How"), ("outcome", "Outcome"), ("open_ends", "Open ends"),
            ("continue", "What an agent needs to continue"))
POINTER = "## Pointer"
ARCHIVE, FETCH, SUBAGENTS, LOCAL = "Archive: ", "Fetch: ", "Subagents: ", "Local (until cleanup): "
EXTRACTED = "Extracted: "
RETIRED = re.compile(r"(?:Archive|Subagents): removed [0-9]{4}-[0-9]{2}-[0-9]{2} after [0-9]+-day retention")
NONE = "None."
UNTRACKED = ("", "none", "not tracked", "n/a", "-")
BLOCK = re.compile(r"[#>`~<|*+_-]|[0-9]+[.)]")


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
    subagents: tuple | None = None  # (path, SHA-256, bytes) of the subagents archive; None without a folder


def one_line(text) -> str:
    return " ".join(text.split())


def inline(text) -> str:
    """text on one line, a backslash before the last character of a leading block marker (`\\#`, `1\\.`)."""
    text = one_line(text)
    marker = BLOCK.match(text)
    return f"{text[:marker.end() - 1]}\\{text[marker.end() - 1:]}" if marker else text


def bullet(item) -> list[str]:
    anchors = ",".join(f"@L{line}" for line in item["anchors"])
    head = [inline(item["text"]), "" if item.get("verified") else "(unverified)", anchors]
    lines = ["- " + " ".join(part for part in head if part)]
    if "as_of" in item:
        as_of, ref = one_line(item["as_of"]), one_line(item["tracked_in"])
        detail = [f"as of {as_of}" if as_of else "", "" if ref.lower() in UNTRACKED else f"tracked in {ref}"]
        if any(detail):
            lines.append("  " + ", ".join(part for part in detail if part))
    for quote in item["quotes"]:
        lines.extend(f"  > {part}" for part in f'"{quote}"'.splitlines())
    return lines


def quoted(path) -> str:
    return "'" + str(path).replace("'", "'\\''") + "'"


def subagents_line(uuid, path, sha256, size) -> str:
    """The subagents archive's pointer line; its fetch unpacks into a folder named after the session."""
    return (f"{SUBAGENTS}{path}, SHA-256 {sha256}, {size} bytes, fetch: mkdir -p {uuid} && tar -xzf {quoted(path)} "
            f"-C {uuid}")


def pointer(meta) -> list[str]:
    packed = [subagents_line(meta.uuid, *meta.subagents)] if meta.subagents else []
    return [f"{ARCHIVE}{meta.archive_path}", f"SHA-256: {meta.sha256}", f"Bytes: {meta.bytes}",
            f"{FETCH}zcat {quoted(meta.archive_path)}", *packed, f"{LOCAL}{meta.local_path}", f"Project: {meta.slug}",
            f"Area: {meta.area}", f"Recipe: {RECIPE}", f"Model: {meta.model_id}/{meta.effort}",
            f"{EXTRACTED}{meta.extracted}"]


def with_subagents(text, archive_path, uuid, subagents) -> str | None:
    """The card with a Subagents line for subagents (path, SHA-256, bytes) after its Fetch line, as a back-filled
    archive needs it: the card as it is when it has that line already, None when its pointer does not name
    archive_path or names another subagents archive."""
    head, mark, tail = text.rpartition(f"\n{POINTER}\n")
    lines = tail.splitlines()
    line, packs = subagents_line(uuid, *subagents), [part for part in lines if part.startswith(SUBAGENTS)]
    fetch = [number for number, part in enumerate(lines) if part.startswith(FETCH)]
    if not mark or [part for part in lines if part.startswith(ARCHIVE)] != [f"{ARCHIVE}{archive_path}"]:
        return None
    if packs:
        return text if packs == [line] else None
    if len(fetch) != 1:
        return None
    lines.insert(fetch[0] + 1, line)
    return head + mark + "\n".join(lines) + "\n"


def retire(text, archive_path, date, days, subagents_path=None) -> tuple[str, bool] | None:
    """(card, retired before) once retention removes its session's files: the pointer's Archive line, and its Subagents
    line when there is one, read `<label>: removed <date> after <days>-day retention`, and its Fetch and Local lines go,
    so it names no missing file. A line retired before stays as it is. None when the pointer names another copy or
    subagents archive than these, or lacks one of them."""
    head, mark, tail = text.rpartition(f"\n{POINTER}\n")
    lines = tail.splitlines()
    named = [line for line in lines if line.startswith(ARCHIVE)]
    packs = [line for line in lines if line.startswith(SUBAGENTS)]
    if not mark or len(named) != 1 or len(packs) != (subagents_path is not None):
        return None
    before = RETIRED.fullmatch(named[0]) is not None
    if not before and named[0] != f"{ARCHIVE}{archive_path}":
        return None
    if packs and not RETIRED.fullmatch(packs[0]) and not packs[0].startswith(f"{SUBAGENTS}{subagents_path}, "):
        return None
    removed = f"removed {date} after {days}-day retention"
    kept = [part if RETIRED.fullmatch(part) or not part.startswith((ARCHIVE, SUBAGENTS))
            else part[:part.index(": ") + 2] + removed
            for part in lines if not part.startswith((FETCH, LOCAL))]
    return head + mark + "\n".join(kept) + "\n", before


def render(meta: CardMeta, summary) -> str:
    lines = [f"# Session {meta.uuid}", "", "## What", "", inline(summary["what"]) or NONE, ""]
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
        folder = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(folder)
        finally:
            os.close(folder)
    finally:
        # Only this call's own temp file, left behind when the write or the rename failed.
        if os.path.exists(temp):
            os.unlink(temp)
    return path, digest, True
