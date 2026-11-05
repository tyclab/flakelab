"""One run of the lane: the scan, then per session render, windows, a summary per window, their merge, the citation
check, the area, the archive copy, the card and its state row; and the run's counts-only journal line."""

from dataclasses import dataclass, replace
from datetime import UTC, datetime
import json
from pathlib import Path
import re
import shutil

from session_archive import archive, cards, cite, render, sources, summarize, windows

COUNTS = ("scanned", "eligible", "done", "held", "review", "windows", "archived", "cards")
FORCED = ("held", "review")
REVIEW = "review.md"
UNCLEAR = "unclear_area"
ROOT_UNREACHABLE = "root_unreachable"
LIBRARY_UNREACHABLE = "library_unreachable"
UNAVAILABLE = "model_unavailable"
BYTES_PER_TOKEN = 3.5
OUTPUT_TOKENS = 4_000
# Failures every later call would meet too: the key, the model id, the service or the network, after the retries.
UNAVAILABLE_ERROR = re.compile(r"http (?:401|403|404|429|5[0-9]{2})|network \w+")


class WorkError(RuntimeError):
    """A work/ file could not be written; it holds the session."""


@dataclass(frozen=True)
class Outcome:
    status: str
    reason: str | None
    usd: float
    card_path: Path | None
    archive_path: Path | None
    windows: int = 0
    card_written: bool = False
    archive_created: bool = False
    detail: str | None = None


@dataclass(frozen=True)
class RunSummary:
    counts: dict
    usd: float
    result: str
    detail: str | None = None


def journal(summary) -> str:
    c = summary.counts
    return (f"session-archive: scanned={c['scanned']} eligible={c['eligible']} done={c['done']} held={c['held']} "
            f"review={c['review']} windows={c['windows']} usd={summary.usd:.2f} archived={c['archived']} "
            f"cards={c['cards']}")


def save(work, name, value):
    """A work file in UTF-8 whatever the locale; a failure is a WorkError naming no path."""
    text = value if isinstance(value, str) else json.dumps(value, ensure_ascii=False, indent=1)
    try:
        (work / name).write_text(text, encoding="utf-8")
    except (OSError, UnicodeError) as error:
        raise WorkError(type(error).__name__) from None


def prepare(work, rendered, parts):
    """work/<uuid>/ afresh, with the rendered text and each window."""
    shutil.rmtree(work, ignore_errors=True)
    try:
        work.mkdir(parents=True, mode=0o700, exist_ok=True)
    except OSError as error:
        raise WorkError(type(error).__name__) from None
    save(work, "rendered.txt", rendered.text)
    for number, part in enumerate(parts, 1):
        save(work, f"w{number}.txt", part.text)


def summarized(transport, cfg, parts, work, charge) -> dict:
    """A summary per window, then their merge; each output is saved in work as it arrives."""
    outputs = []
    for number, part in enumerate(parts, 1):
        outputs.append(summarize.window(transport, cfg, part, cfg.areas, charge=charge))
        save(work, f"w{number}.json", outputs[-1])
    merged = summarize.merge(transport, cfg, outputs, cfg.areas, charge=charge)
    save(work, "summary.json", merged)
    return merged


def projected(cfg, parts) -> float:
    """A conservative price of a session before its first call: every window and the merge priced as the largest window
    sent (BYTES_PER_TOKEN bytes a token) plus OUTPUT_TOKENS of output."""
    per_input, per_output = summarize.rates(cfg.model)
    largest = max(len(part.text.encode()) for part in parts)
    return (len(parts) + 1) * (largest / BYTES_PER_TOKEN * per_input + OUTPUT_TOKENS * per_output) / 1e6


def blank(summary) -> bool:
    return not summary["what"].strip() and not any(summary[name] for name in cite.LISTS)


def run_session(cfg, store, transport, candidate, run_id, dry_run=False, keep=False, *, now=None) -> Outcome:
    """One eligible session through the pipeline; a failure after the scan holds it, and so does an interrupt (SIGTERM
    at the unit's timeout, Ctrl-C) as timeout before it ends the run. A dry run counts its windows."""
    c, now = candidate, now or datetime.now(UTC)
    if dry_run:
        try:
            return Outcome("skipped", "dry_run", 0.0, None, None, len(windows.split(render.render(c.path))))
        except Exception:
            return Outcome("skipped", "dry_run", 0.0, None, None)
    stat = {"size": c.size, "mtime": c.mtime, "last_entry": c.last_entry}
    budget, spent, models, parts = summarize.Budget(store, run_id, cfg.run_cap_usd), [], [], []
    work = cfg.state_dir / "work" / c.uuid

    def charge(done):
        spent.append(done.usd)
        models.append(done.model_id)
        budget.charge(c.uuid, done.model_id, done.usage, done.usd)

    def hold(reason, copied=None, created=False):
        # A hold keeps the last card's area, card hash and archive path in the store, and the work directory.
        store.record_session(c.uuid, c.slug, c.sha256, "held", reason, **stat)
        return Outcome("held", reason, sum(spent), None, copied, len(parts), archive_created=created)

    def finished(outcome):
        if not keep:
            shutil.rmtree(work, ignore_errors=True)
        return outcome

    def through() -> Outcome:
        try:
            rendered = render.render(c.path)
            parts.extend(windows.split(rendered))
        except OSError:
            return hold("unreadable")  # its message names the path: never shown
        except Exception:
            return hold("render_error")
        if not parts:
            return hold("unreadable")
        cost = projected(cfg, parts)
        if cost > cfg.run_cap_usd:
            return hold("too_large")
        if cost > cfg.run_cap_usd - store.run_usd(run_id):
            return Outcome("skipped", "capped", 0.0, None, None)
        try:
            prepare(work, rendered, parts)
            merged = summarized(transport, cfg, parts, work, charge)
        except WorkError:
            return hold("work_error")
        except (summarize.UnknownModel, OSError):
            raise
        except summarize.SummarizeError as error:
            if UNAVAILABLE_ERROR.fullmatch(error.detail):
                # The transport failed, not the session: no hold, its row and its earlier card stay as they were.
                return finished(Outcome("skipped", UNAVAILABLE, sum(spent), None, None, len(parts),
                                        detail=error.detail))
            return hold(error.reason)
        except Exception:
            return hold("model_error")
        if blank(merged):
            return hold("unparsable")
        try:
            summary = cite.check(merged, rendered)
        except Exception:
            return hold("render_error")
        area = cfg.areas.get(summary["area"])
        if area is None:
            with (cfg.state_dir / REVIEW).open("a", encoding="utf-8") as entries:
                entries.write(f"- {now.date().isoformat()} {c.uuid} {UNCLEAR}\n")
            store.record_session(c.uuid, c.slug, c.sha256, "review", UNCLEAR, **stat)
            return finished(Outcome("review", UNCLEAR, sum(spent), None, None, len(parts)))
        try:
            copied, created = archive.copy(cfg.root, c.slug, c.uuid, c.path, c.sha256)
        except archive.ArchiveError:
            return hold("archive_error")
        meta = cards.CardMeta(c.uuid, c.slug, area.name, copied, c.sha256, c.size, c.path, models[-1], cfg.effort,
                              now.date().isoformat())
        try:
            text = cards.render(meta, summary)
        except Exception:
            return hold("render_error", copied, created)
        try:
            card, card_hash, written = cards.write(area.library, c.uuid, text)
        except FileNotFoundError:
            return hold("library_missing", copied, created)
        except (OSError, UnicodeError):
            return hold("card_error", copied, created)
        store.record_session(c.uuid, c.slug, c.sha256, "done", area=area.name, card_hash=card_hash,
                             archive_path=str(copied), **stat)
        return finished(Outcome("done", None, sum(spent), card, copied, len(parts), written, created))

    try:
        return through()
    except Exception:
        raise
    except BaseException:
        # SystemExit from the SIGTERM handler or KeyboardInterrupt: hold it, so three of them unblock the queue.
        hold("timeout")
        raise


def forced(store, candidate):
    """--session: the candidate past its quiet days, its holds and a review."""
    c = candidate
    if c.reason == "quiet":
        try:
            sha256, spoke = sources.digest(c.path)
        except OSError:
            return replace(c, reason="unreadable")
        c = replace(c, sha256=sha256,
                    reason=sources.verdict(store.session(c.uuid), sha256) if spoke else "no_operator_text")
    return replace(c, reason="eligible") if c.reason in FORCED else c


def tally(counts, outcome):
    counts[outcome.status] = counts.get(outcome.status, 0) + 1
    counts["windows"] += outcome.windows
    counts["archived"] += outcome.archive_created
    counts["cards"] += outcome.card_written


def lost(store, folder) -> bool:
    """A folder this box claimed before that has no .owner now: an unmounted share's bare mount point."""
    return store.claimed(folder) and archive.owner(folder) is None


def take(cfg, store, transport, queue, run_id, counts, keep, now) -> tuple[str, str | None]:
    """(result, detail) of the queue's sessions. A box-level failure is the run's, not a session's: an unreachable root
    or library takes none, a model API that is unavailable stops the run at the session in flight, which is not held."""
    if cfg.root is None or not Path(cfg.root).is_dir() or lost(store, cfg.root):
        return ROOT_UNREACHABLE, None
    if any(lost(store, area.library) for area in cfg.areas.values()):
        return LIBRARY_UNREACHABLE, None
    budget = summarize.Budget(store, run_id, cfg.run_cap_usd)
    for c in queue:
        if not budget.allow():
            return "capped", None
        outcome = run_session(cfg, store, transport, c, run_id, keep=keep, now=now)
        if outcome.reason == "capped":  # it fits the cap, not what this run has left: the next run takes it
            return "capped", None
        tally(counts, outcome)
        if outcome.reason == UNAVAILABLE:
            return UNAVAILABLE, outcome.detail
    return "ok", None


def run(cfg, store, transport, now, limit=None, session=None, dry_run=False, keep=False) -> RunSummary:
    """Eligible sessions, oldest first, until run_sessions (or limit) are taken or the run cap is spent; the session in
    flight always finishes. result: ok, capped, root_unreachable, library_unreachable, model_unavailable, or for
    --session missing or the reason it was not taken."""
    summarize.rates(cfg.model)  # an unpriced model is a config error, before any call
    found = sources.scan(cfg, store, now)
    counts = dict.fromkeys(COUNTS, 0) | {"scanned": len(found),
                                         "unreadable": sum(c.reason == "unreadable" for c in found)}
    if session is not None:
        found = [forced(store, c) for c in found if c.uuid == session]
        if not found:
            return RunSummary(counts, 0.0, "missing")
    queue = [c for c in found if c.reason == "eligible"]
    counts["eligible"] = len(queue)
    queue = queue[:min(limit or cfg.run_sessions, cfg.run_sessions)]
    if session is not None and not queue:
        return RunSummary(counts, 0.0, ([c.reason for c in found if c.reason != "artifact"] or ["artifact"])[0])
    if dry_run:
        for c in queue:
            tally(counts, run_session(cfg, store, transport, c, None, dry_run=True))
        return RunSummary(counts, 0.0, "dry_run")
    run_id, result, detail = store.start_run(), "error", None
    try:
        result, detail = take(cfg, store, transport, queue, run_id, counts, keep, now)
    finally:
        # A --session run sees one session, not the backlog: it records no eligible count, so status keeps the last
        # full run's.
        store.finish_run(run_id, result, counts if session is None else {**counts, "eligible": None})
    return RunSummary(counts, store.run_usd(run_id), result, detail)
