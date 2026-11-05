"""One run of the lane: the scan, then per session render, windows, a summary per window, their merge, the citation
check, the area, the archive copy, the card and its state row; and the run's counts-only journal line."""

from dataclasses import dataclass, replace
from datetime import UTC, datetime
import json
from pathlib import Path
import shutil

from session_archive import archive, cards, cite, render, sources, summarize, windows

COUNTS = ("scanned", "eligible", "done", "held", "review", "windows", "archived", "cards")
FORCED = ("held", "review")
REVIEW = "review.md"
UNCLEAR = "unclear_area"


@dataclass(frozen=True)
class Outcome:
    status: str
    reason: str | None
    usd: float
    card_path: Path | None
    archive_path: Path | None
    windows: int = 0
    card_written: bool = False


@dataclass(frozen=True)
class RunSummary:
    counts: dict
    usd: float
    result: str


def journal(summary) -> str:
    c = summary.counts
    return (f"session-archive: scanned={c['scanned']} eligible={c['eligible']} done={c['done']} held={c['held']} "
            f"review={c['review']} windows={c['windows']} usd={summary.usd:.2f} archived={c['archived']} "
            f"cards={c['cards']}")


def save(work, name, value):
    (work / name).write_text(value if isinstance(value, str) else json.dumps(value, ensure_ascii=False, indent=1))


def summarized(transport, cfg, parts, work, charge) -> dict:
    """A summary per window, then their merge; each output is saved in work as it arrives."""
    outputs = []
    for number, part in enumerate(parts, 1):
        outputs.append(summarize.window(transport, cfg, part, cfg.areas, charge=charge))
        save(work, f"w{number}.json", outputs[-1])
    merged = summarize.merge(transport, cfg, outputs, cfg.areas, charge=charge)
    save(work, "summary.json", merged)
    return merged


def run_session(cfg, store, transport, candidate, run_id, dry_run=False, keep=False, *, now=None) -> Outcome:
    """One eligible session through the pipeline; a failure after the scan holds it, a dry run counts its windows."""
    c, now = candidate, now or datetime.now(UTC)
    try:
        rendered = render.render(c.path)
    except OSError:
        rendered = None  # its message names the path: never shown
    parts = [] if rendered is None else windows.split(rendered)
    if dry_run:
        return Outcome("skipped", "dry_run", 0.0, None, None, len(parts))
    stat = {"size": c.size, "mtime": c.mtime, "last_entry": c.last_entry}
    budget, spent, models = summarize.Budget(store, run_id, cfg.run_cap_usd), [], []
    work = cfg.state_dir / "work" / c.uuid

    def charge(done):
        spent.append(done.usd)
        models.append(done.model_id)
        budget.charge(c.uuid, done.model_id, done.usage, done.usd)

    def hold(reason, copied=None):
        # A hold keeps the last card's area, card hash and archive path in the store, and the work directory.
        store.record_session(c.uuid, c.slug, c.sha256, "held", reason, **stat)
        return Outcome("held", reason, sum(spent), None, copied, len(parts))

    def finished(outcome):
        if not keep:
            shutil.rmtree(work, ignore_errors=True)
        return outcome

    if not parts:
        return hold("unreadable")
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir(parents=True, mode=0o700, exist_ok=True)
    save(work, "rendered.txt", rendered.text)
    for number, part in enumerate(parts, 1):
        save(work, f"w{number}.txt", part.text)
    try:
        merged = summarized(transport, cfg, parts, work, charge)
    except (summarize.UnknownModel, OSError):
        raise
    except summarize.SummarizeError as error:
        return hold(error.reason)
    except Exception:
        return hold("model_error")
    summary = cite.check(merged, rendered)
    area = cfg.areas.get(summary["area"])
    if area is None:
        with (cfg.state_dir / REVIEW).open("a") as entries:
            entries.write(f"- {now.date().isoformat()} {c.uuid} {UNCLEAR}\n")
        store.record_session(c.uuid, c.slug, c.sha256, "review", UNCLEAR, **stat)
        return finished(Outcome("review", UNCLEAR, sum(spent), None, None, len(parts)))
    try:
        copied = archive.copy(cfg.root, c.slug, c.uuid, c.path, c.sha256)
    except archive.ArchiveError:
        return hold("archive_error")
    meta = cards.CardMeta(c.uuid, c.slug, area.name, copied, c.sha256, c.size, c.path, models[-1], cfg.effort,
                          now.date().isoformat())
    try:
        card, card_hash, written = cards.write(area.library, c.uuid, cards.render(meta, summary))
    except FileNotFoundError:
        return hold("library_missing", copied)
    except OSError:
        return hold("card_error", copied)
    store.record_session(c.uuid, c.slug, c.sha256, "done", area=area.name, card_hash=card_hash,
                         archive_path=str(copied), **stat)
    return finished(Outcome("done", None, sum(spent), card, copied, len(parts), written))


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
    counts["archived"] += outcome.archive_path is not None
    counts["cards"] += outcome.card_written


def run(cfg, store, transport, now, limit=None, session=None, dry_run=False, keep=False) -> RunSummary:
    """Eligible sessions, oldest first, until run_sessions (or limit) are taken or the run cap is spent; the session in
    flight always finishes. result: ok, capped, or for --session missing or the reason it was not taken."""
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
    run_id, result = store.start_run(), "error"
    budget = summarize.Budget(store, run_id, cfg.run_cap_usd)
    try:
        for c in queue:
            if not budget.allow():
                result = "capped"
                break
            tally(counts, run_session(cfg, store, transport, c, run_id, keep=keep, now=now))
        else:
            result = "ok"
    finally:
        store.finish_run(run_id, result, counts)
    return RunSummary(counts, store.run_usd(run_id), result)
