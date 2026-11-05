"""Command line of `flakelab session-archive`: run, status and review; exit 0 ok, 1 failure, 2 usage error."""

import os
import sys

if __name__ == "__main__":
    # Run as a script, sys.path starts in this package, where secrets.py would shadow the stdlib's: start at lib/.
    sys.path[0] = os.environ.get("SESSION_ARCHIVE_LIB") or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

import argparse
import uuid

PROG = "flakelab session-archive"


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


def run(args: argparse.Namespace) -> int:
    return 0


def status(args: argparse.Namespace) -> int:
    return 0


def review(args: argparse.Namespace) -> int:
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


def main(argv: list[str]) -> int:
    try:
        args = parser().parse_args(argv)
    except SystemExit as stop:
        return stop.code if isinstance(stop.code, int) else 2
    return args.handler(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
