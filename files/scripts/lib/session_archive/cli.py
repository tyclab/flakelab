"""Command line of `flakelab session-archive`: run, status and review; exit 0 ok, 1 failure, 2 usage error. A run prints
one counts-only journal line; no message names a path or a secret."""

import os
import sys

if __name__ == "__main__":
    # Run as a script, sys.path starts in this package, where secrets.py would shadow the stdlib's: start at lib/.
    sys.path[0] = os.environ.get("SESSION_ARCHIVE_LIB") or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

import argparse
import contextlib
from datetime import UTC, datetime
import fcntl
import json
import signal
import sqlite3
import uuid

from session_archive import archive, config, pipeline, retention, sources, store, summarize
from session_archive import secrets as lane_secrets

PROG = "flakelab session-archive"
STATE_DB = "state.sqlite3"
ROOT_STATE = {None: "not configured", True: "reachable", False: "unreachable"}
OWNER_STATE = {None: "unclaimed", True: "this box", False: "another box"}


class Failure(RuntimeError):
    """A refusal whose message names no path."""


FAILURES = (Failure, config.ConfigError, lane_secrets.MissingSecret, store.StoreError, sources.SourceError,
            summarize.UnknownModel, archive.ArchiveError)


def session_id(value: str) -> str:
    try:
        return str(uuid.UUID(value))
    except ValueError:
        raise argparse.ArgumentTypeError(f"not a session uuid: {value}") from None


def session_count(value: str) -> int:
    try:
        count = int(value)
    except ValueError:
        count = 0
    if count < 1:
        raise argparse.ArgumentTypeError(f"takes a whole number, 1 or more: {value}")
    return count


@contextlib.contextmanager
def single(state_dir):
    """True while this process holds the lane's lock; False when another instance does."""
    state_dir.mkdir(parents=True, exist_ok=True)
    with open(state_dir / "lock", "a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            ours = True
        except BlockingIOError:
            ours = False
        yield ours


def opened(cfg):
    return contextlib.closing(store.Store(cfg.state_dir / STATE_DB))


def reader(cfg):
    """The state database read-only, or None before a run has made it: status and review create nothing."""
    path = cfg.state_dir / STATE_DB
    return contextlib.closing(store.Store(path, readonly=True)) if path.is_file() else contextlib.nullcontext()


def peek(cfg):
    """A dry run's store: the state database read-only, or an empty one in memory before a run has made it."""
    path = cfg.state_dir / STATE_DB
    return contextlib.closing(store.Store(path, readonly=True) if path.is_file() else store.Store(":memory:"))


def folders(cfg) -> list:
    """The archive root and every library, each once."""
    return list(dict.fromkeys([*([cfg.root] if cfg.root else []), *(area.library for area in cfg.areas.values())]))


def refuse_foreign(cfg, machine_id):
    """Every marker is read before any is written: one naming another box refuses the run and claims nothing."""
    if any(archive.owner(folder) not in (None, machine_id) for folder in folders(cfg)):
        raise Failure("the archive root or a library is owned by another box (.owner)")


def claim(cfg, db, machine_id):
    """Marks each folder this box may write and records the first claim. A folder claimed before that lost its marker
    (an unmounted share's mount point) is not claimed again: the run reports it unreachable. A marker another box wrote
    since refuse_foreign read them all refuses the run as well."""
    for folder in folders(cfg):
        if pipeline.lost(db, folder):
            continue
        if not archive.check_owner(folder, machine_id):
            raise Failure("the archive root or a library is owned by another box (.owner)")
        if archive.owner(folder) == machine_id:
            db.claim(folder, machine_id)


def stop(signum, frame):
    """SIGTERM (the unit's timeout, systemctl stop) as SystemExit, so the session in flight is held first."""
    raise SystemExit(128 + signum)


def transport(env):
    try:
        return summarize.ApiTransport(lane_secrets.api_key(env))
    except ValueError as error:  # names the key, never its value
        raise Failure(str(error)) from None


def run(args: argparse.Namespace, env) -> int:
    cfg = config.load(env)
    if cfg.root is None and not args.dry_run:
        raise Failure("SESSION_ARCHIVE_ROOT is not set: a run copies each session into the archive root")
    machine_id = archive.machine_id(env)
    options = {"limit": args.limit, "session": args.session, "keep": args.keep}
    if args.dry_run:
        # It writes nothing, not even the lock or the state database, so it counts beside a run.
        refuse_foreign(cfg, machine_id)
        with peek(cfg) as db:
            done = pipeline.run(cfg, db, None, datetime.now(UTC), dry_run=True, **options)
    else:
        previous = signal.signal(signal.SIGTERM, stop)
        try:
            with single(cfg.state_dir) as ours:
                if not ours:
                    print("already running")
                    return 0
                model = transport(env)
                refuse_foreign(cfg, machine_id)
                with opened(cfg) as db:
                    claim(cfg, db, machine_id)
                    done = pipeline.run(cfg, db, model, datetime.now(UTC), **options)
        finally:
            signal.signal(signal.SIGTERM, signal.SIG_DFL if previous is None else previous)
    if done.result == "missing":
        raise Failure(f"session {args.session} is not under the configured projects")
    print(pipeline.journal(done))
    if done.result == pipeline.ROOT_UNREACHABLE:
        raise Failure("the archive root is unreachable: the run took no session")
    if done.result == pipeline.LIBRARY_UNREACHABLE:
        raise Failure("a library is unreachable: the run took no session")
    if done.result == pipeline.UNAVAILABLE:
        raise Failure(f"the model API is unavailable ({done.detail}): the run stopped, holding no session")
    if done.result == retention.ERROR:
        raise Failure(f"retention could not prune {done.counts['prune_errors']} session(s) ({done.detail}): the next "
                      "run retries")
    if args.session and not done.counts["eligible"]:
        print(f"session-archive: session {args.session} not taken: {done.result}", file=sys.stderr)
    return 0


def status(args: argparse.Namespace, env) -> int:
    """The store's account, without reading the state root: eligible is what the last full run (not --session)
    counted, None until one has finished."""
    cfg = config.load(env)
    machine_id = archive.machine_id(env)
    last, held, review, eligible, usd, root_lost = None, [], [], None, 0.0, False
    with reader(cfg) as db:
        if db is not None:
            last, held, review, eligible = db.last_run(), db.held(), db.review(), db.last_count("eligible")
            usd = db.run_usd(last["run_id"]) if last else 0.0
            root_lost = cfg.root is not None and pipeline.lost(db, cfg.root)
    marks = [mark for mark in map(archive.owner, folders(cfg)) if mark is not None]
    report = {
        "last_run": last["started"] if last else None, "last_result": last["result"] if last else None,
        "eligible": eligible, "held": len(held), "review": len(review),
        "last_run_usd": round(usd, 6), "run_sessions": cfg.run_sessions,
        "root_ok": None if cfg.root is None else cfg.root.is_dir() and not root_lost,
        "owner_ok": all(mark == machine_id for mark in marks) if marks else None,
    }
    if args.json:
        print(json.dumps(report))
        return 0
    print("\n".join([
        f"last run: {last['started']} ({last['result'] or 'no result'}, {usd:.2f} USD)" if last else "last run: never",
        f"eligible at the last full run: {'not counted yet' if eligible is None else eligible} "
        f"({cfg.run_sessions} per run)",
        f"held: {len(held)}", *(f"  {row['uuid']} {row['reason']}, {row['holds']} hold(s)" for row in held),
        f"waiting for review: {len(review)}",
        f"archive root: {ROOT_STATE[report['root_ok']]}", f"owner: {OWNER_STATE[report['owner_ok']]}",
    ]))
    return 0


def review(args: argparse.Namespace, env) -> int:
    """One line per session waiting for review: the last review.md has for it, else one from its state row."""
    cfg = config.load(env)
    with reader(cfg) as db:
        waiting = db.review() if db is not None else []
    try:
        entries = (cfg.state_dir / pipeline.REVIEW).read_text(encoding="utf-8").splitlines()
    except FileNotFoundError:
        entries = []
    latest = {named.group(): line for line in entries if (named := sources.UUID_IN_NAME.search(line)) is not None}
    shown = [latest.get(row["uuid"]) or f"- {row['updated'][:10]} {row['uuid']} {row['reason']}" for row in waiting]
    print("\n".join(shown) if shown else "no session waits for review")
    return 0


def parser() -> argparse.ArgumentParser:
    top = argparse.ArgumentParser(
        prog=PROG,
        description="Archive agent sessions and write their summary cards.",
        epilog="Exit codes: 0 ok, 1 failure, 2 usage error.",
    )
    commands = top.add_subparsers(dest="command", required=True, metavar="{run,status,review}")
    run_cmd = commands.add_parser("run", help="archive each eligible session and write its card")
    run_cmd.add_argument("--session", type=session_id, metavar="UUID", help="only this session, past quiet days and holds")
    run_cmd.add_argument("--dry-run", action="store_true", help="count what a run would do: no model call, no write")
    run_cmd.add_argument("--limit", type=session_count, metavar="N", help="at most N sessions in this run")
    run_cmd.add_argument("--keep", action="store_true", help="keep each session's work directory after its card")
    run_cmd.set_defaults(handler=run)
    status_cmd = commands.add_parser("status", help="last run, backlog, held and review counts")
    status_cmd.add_argument("--json", action="store_true", help="one JSON object instead of lines")
    status_cmd.set_defaults(handler=status)
    commands.add_parser("review", help="the sessions waiting for review").set_defaults(handler=review)
    return top


def main(argv: list[str], env=None) -> int:
    try:
        args = parser().parse_args(argv)
    except SystemExit as stop:
        return stop.code if isinstance(stop.code, int) else 2
    try:
        return args.handler(args, os.environ if env is None else env)
    except FAILURES as error:
        message = str(error)
    except sqlite3.Error as error:
        message = f"the state database failed: {error}"
    except OSError as error:  # its filename is a path: only the reason is shown
        message = f"failed: {error.strerror or type(error).__name__}"
    print(f"session-archive: {message}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
