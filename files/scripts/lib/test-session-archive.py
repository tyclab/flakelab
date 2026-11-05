"""Offline suite for `flakelab session-archive`: the shim and lib/session_archive/, run by test-session-archive."""

import contextlib
from datetime import UTC, datetime, timedelta
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from session_archive import cli, config, sources, store
from session_archive import secrets as lane_secrets

SHIM = Path(__file__).resolve().parent.parent / "session-archive"
UUID = "0f9b6c2e-3a41-4d7e-9c55-1b2a3c4d5e6f"
OTHER_UUID = "7c1d2e3f-4a5b-4c6d-8e7f-9a0b1c2d3e4f"
THIRD_UUID = "3e2d1c0b-9a8f-4e7d-a6c5-b4a39281706f"
NOW = datetime(2026, 1, 20, 12, 0, tzinfo=UTC)
OLD = NOW - timedelta(days=10)
SLUG, OTHER_SLUG = "-work-alpha", "-work-beta"
LANE_KEY = "SESSION_ARCHIVE_ANTHROPIC_API_KEY"


def stamp(when):
    return when.isoformat().replace("+00:00", "Z")


def said(kind, content, when=OLD):
    return {"type": kind, "timestamp": stamp(when), "message": {"role": kind, "content": content}}


def spoken(when=OLD):
    return [said("user", "please sort the widget list", when),
            said("assistant", [{"type": "text", "text": "Sorted by name."}], when + timedelta(minutes=1))]


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


class Scratch(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.tmp = Path(tmp.name)
        areas = {"lab": {"description": "Lab work.", "library": str(self.tmp / "library"),
                         "projects": [SLUG, OTHER_SLUG]}}
        self.env = {"HOME": str(self.tmp / "home"), "FLAKELAB_STATE_ROOT": str(self.tmp / "state"),
                    "FLAKELAB_SECRETS_RENDER": str(self.tmp / "no-render"), "SESSION_ARCHIVE_AREAS": json.dumps(areas)}
        self.cfg = config.load(self.env)
        self.store = store.Store(self.cfg.state_dir / "state.sqlite3")
        self.addCleanup(self.store.close)

    def transcript(self, records, uuid=UUID, slug=SLUG, modified=OLD, append=False):
        path = self.tmp / "state/claude/projects" / slug / f"{uuid}.jsonl"
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a" if append else "w") as fh:
            fh.writelines(json.dumps(record) + "\n" for record in records)
        os.utime(path, (modified.timestamp(), modified.timestamp()))
        return path

    def scan(self, cfg=None):
        found = sources.scan(cfg or self.cfg, self.store, NOW)
        self.assertEqual(len(found), len({(c.uuid, c.path) for c in found}))
        return {c.uuid: c for c in found if c.reason != "artifact"}


class ConfigTest(unittest.TestCase):
    def test_config_parses_areas_json(self):
        areas = {"lab": {"description": "Lab work.", "library": "/srv/library/lab", "projects": ["-a", "-b"]},
                 "home": {"description": "Home matters.", "library": "/srv/library/home", "projects": ["-c", "-b"]}}
        cfg = config.load({"HOME": "/home/someone", "FLAKELAB_STATE_ROOT": "/srv/state",
                           "SESSION_ARCHIVE_ROOT": "/srv/archive", "SESSION_ARCHIVE_AREAS": json.dumps(areas),
                           "SESSION_ARCHIVE_MODEL": "claude-sonnet-5", "SESSION_ARCHIVE_QUIET_DAYS": "5",
                           "SESSION_ARCHIVE_RUN_CAP_USD": "1.5", "SESSION_ARCHIVE_RUN_SESSIONS": "7"})
        self.assertEqual(cfg.areas["lab"], config.Area("lab", "Lab work.", Path("/srv/library/lab"), ["-a", "-b"]))
        self.assertEqual(cfg.areas["home"].projects, ["-c", "-b"])
        self.assertEqual(cfg.projects, ["-a", "-b", "-c"])
        self.assertEqual((cfg.root, cfg.state_root), (Path("/srv/archive"), Path("/srv/state")))
        self.assertEqual((cfg.model, cfg.effort, cfg.quiet_days, cfg.run_cap_usd, cfg.run_sessions),
                         ("claude-sonnet-5", "low", 5, 1.5, 7))
        self.assertEqual(cfg.state_dir, Path("/home/someone/.local/state/flakelab/session-archive"))
        bare = config.load({"HOME": "/home/someone", "XDG_STATE_HOME": "/srv/xdg", "SESSION_ARCHIVE_AREAS": "{}"})
        self.assertEqual((bare.areas, bare.projects, bare.root, bare.state_root), ({}, [], None, None))
        self.assertEqual((bare.model, bare.effort, bare.quiet_days, bare.run_cap_usd, bare.run_sessions),
                         ("claude-haiku-5-5", "low", 3, 2.0, 20))
        self.assertEqual(bare.state_dir, Path("/srv/xdg/flakelab/session-archive"))
        for raw in ("[]", "{", json.dumps({"lab": {"description": "x", "projects": ["-a"]}}),
                    json.dumps({"lab": {"description": "x", "library": "rel/lib", "projects": ["-a"]}}),
                    json.dumps({"lab": {"description": "x", "library": "/srv/l", "projects": ["../up"]}}),
                    json.dumps({"unclear": {"description": "x", "library": "/srv/l", "projects": ["-a"]}})):
            with self.subTest(areas=raw), self.assertRaisesRegex(config.ConfigError, "^SESSION_ARCHIVE_AREAS"):
                config.load({"HOME": "/home/someone", "SESSION_ARCHIVE_AREAS": raw})
        for name, raw in (("SESSION_ARCHIVE_RUN_SESSIONS", "0"), ("SESSION_ARCHIVE_RUN_CAP_USD", "nan"),
                          ("SESSION_ARCHIVE_QUIET_DAYS", "x"), ("SESSION_ARCHIVE_ROOT", "relative/root")):
            with self.subTest(name=name), self.assertRaisesRegex(config.ConfigError, f"^{name}"):
                config.load({"HOME": "/home/someone", name: raw})


class SecretsTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.tmp = Path(tmp.name)
        self.file = self.tmp / "secrets.env"
        self.home_file = self.tmp / "home/.config/flakelab/secrets.env"
        self.env = {"HOME": str(self.tmp / "home"), "FLAKELAB_SECRETS_ENV": str(self.file),
                    "FLAKELAB_SECRETS_RENDER": str(self.tmp / "no-render")}

    def missing(self, env):
        with self.assertRaises(lane_secrets.MissingSecret) as caught:
            lane_secrets.api_key(env)
        self.assertIsNone(caught.exception.__context__)
        return str(caught.exception)

    def test_secrets_missing_key_names_key_only(self):
        self.file.write_text("OTHER_TOKEN=unrelated-one\nexport NOT_THE_LANE_KEY='unrelated-two'\n")
        message = self.missing(self.env)
        self.assertEqual(message, f"{LANE_KEY} is not set in the flakelab secrets file")
        self.assertEqual(self.missing({**self.env, "FLAKELAB_SECRETS_ENV": ""}), message)

    def test_secrets_ignores_plain_anthropic_api_key(self):
        self.file.write_text("ANTHROPIC_API_KEY=plain-billing-one\nexport ANTHROPIC_API_KEY='plain-billing-two'\n")
        message = self.missing({**self.env, "ANTHROPIC_API_KEY": "plain-billing-three"})
        self.assertNotIn("plain-billing", message)

    def test_secrets_reads_first_readable_file(self):
        self.home_file.parent.mkdir(parents=True)
        self.home_file.write_text(f"{LANE_KEY}='lane-home-value'\n")
        self.assertEqual(lane_secrets.api_key({**self.env, "FLAKELAB_SECRETS_ENV": ""}), "lane-home-value")
        self.file.write_text(f'# lane\r\nexport {LANE_KEY}="lane-env-value"  # set by hand\r\n')
        self.assertEqual(lane_secrets.api_key(self.env), "lane-env-value")
        self.file.write_text("OTHER_TOKEN=unrelated-one\n")
        self.missing(self.env)


class StoreTest(Scratch):
    def test_store_run_usd_sums_ledger(self):
        run, other = self.store.start_run(), self.store.start_run()
        self.assertNotEqual(run, other)
        usage = {"input_tokens": 1000, "output_tokens": 200}
        self.store.ledger_add(run, UUID, "claude-haiku-5-5", usage, 0.25)
        self.store.ledger_add(run, UUID, "claude-haiku-5-5", usage, 0.5)
        self.store.ledger_add(other, OTHER_UUID, "claude-haiku-5-5", usage, 1.0)
        self.assertAlmostEqual(self.store.run_usd(run), 0.75)
        self.assertAlmostEqual(self.store.run_usd(other), 1.0)
        self.assertEqual(self.store.run_usd("no-such-run"), 0.0)
        self.store.finish_run(other, "ok", {"done": 1, "held": 0})
        last = self.store.last_run()
        self.assertEqual((last["run_id"], last["result"], json.loads(last["counts"])), (other, "ok", {"done": 1, "held": 0}))

    def test_store_record_session_counts_holds(self):
        self.assertIsNone(self.store.session(UUID))
        self.store.record_session(UUID, SLUG, "a" * 64, "done", area="lab", card_hash="c1", archive_path="/srv/a.gz")
        self.store.record_session(UUID, SLUG, "b" * 64, "held", reason="model_error")
        self.store.record_session(UUID, SLUG, "b" * 64, "held", reason="unparsable")
        row = self.store.session(UUID)
        self.assertEqual((row["status"], row["holds"], row["reason"], row["sha256"]), ("held", 2, "unparsable", "b" * 64))
        self.assertEqual((row["area"], row["card_hash"], row["archive_path"]), ("lab", "c1", "/srv/a.gz"))
        self.assertEqual([r["uuid"] for r in self.store.held()], [UUID])
        self.store.record_session(UUID, SLUG, "b" * 64, "done", area="lab", card_hash="c2", archive_path="/srv/b.gz")
        self.assertEqual((self.store.session(UUID)["holds"], self.store.held()), (0, []))
        self.store.record_session(OTHER_UUID, SLUG, "c" * 64, "review", reason="unclear_area")
        self.assertEqual([r["uuid"] for r in self.store.review()], [OTHER_UUID])
        with self.assertRaises(ValueError):
            self.store.record_session(UUID, SLUG, "b" * 64, "finished")


class ScanTest(Scratch):
    def test_scan_skips_live_file(self):
        self.transcript(spoken(), modified=NOW - timedelta(seconds=60))
        self.transcript(spoken(), uuid=OTHER_UUID)
        found = self.scan()
        self.assertEqual((found[UUID].reason, found[OTHER_UUID].reason), ("live", "eligible"))

    def test_scan_skips_quiet_period(self):
        recent = NOW - timedelta(days=2)
        self.transcript(spoken() + spoken(recent), modified=recent)
        undated = [{"type": "user", "message": {"role": "user", "content": "check the widget list"}}]
        self.transcript(undated, uuid=OTHER_UUID, modified=NOW - timedelta(hours=36))
        self.transcript(spoken(), uuid=THIRD_UUID, modified=NOW - timedelta(hours=1))
        found = self.scan()
        self.assertEqual((found[UUID].reason, found[UUID].last_entry), ("quiet", recent + timedelta(minutes=1)))
        self.assertEqual((found[OTHER_UUID].reason, found[OTHER_UUID].last_entry), ("quiet", None))
        self.assertEqual((found[THIRD_UUID].reason, found[THIRD_UUID].last_entry), ("eligible", OLD + timedelta(minutes=1)))
        found = self.scan(config.load({**self.env, "SESSION_ARCHIVE_QUIET_DAYS": "1"}))
        self.assertEqual((found[UUID].reason, found[OTHER_UUID].reason), ("eligible", "eligible"))

    def test_scan_marks_changed_sha_eligible(self):
        path = self.transcript(spoken())
        first = self.scan()[UUID]
        self.assertEqual((first.reason, first.sha256, first.slug, first.path), ("eligible", sha256(path), SLUG, path))
        self.store.record_session(UUID, SLUG, first.sha256, "done", area="lab")
        self.transcript(spoken(OLD + timedelta(hours=1)), append=True)
        grown = self.scan()[UUID]
        self.assertEqual((grown.reason, grown.sha256), ("eligible", sha256(path)))
        self.assertNotEqual(grown.sha256, first.sha256)

    def test_scan_skips_unchanged(self):
        path = self.transcript(spoken())
        self.store.record_session(UUID, SLUG, sha256(path), "done", area="lab")
        found = self.scan()[UUID]
        self.assertEqual((found.reason, found.sha256, found.last_entry), ("unchanged", sha256(path), OLD + timedelta(minutes=1)))

    def test_scan_keeps_review_until_sha_changes(self):
        path = self.transcript(spoken())
        self.store.record_session(UUID, SLUG, sha256(path), "review", reason="unclear_area")
        self.assertEqual(self.scan()[UUID].reason, "review")
        self.transcript(spoken(OLD + timedelta(hours=1)), append=True)
        self.assertEqual(self.scan()[UUID].reason, "eligible")

    def test_scan_skips_no_operator_text(self):
        silent = [
            {"type": "summary", "summary": "Widget chores", "leafUuid": OTHER_UUID},
            said("user", "<system-reminder>the date changed</system-reminder>"),
            said("user", [{"type": "text", "text": "  <system-reminder>a file changed</system-reminder>"}]),
            said("user", [{"type": "tool_result", "tool_use_id": "toolu_01", "content": "3 widgets"}]),
            said("user", [{"type": "tool_result", "tool_use_id": "toolu_02",
                           "content": [{"type": "text", "text": "listed"}]}]),
            said("user", ""),
            said("assistant", [{"type": "text", "text": "Listing the widgets."}]),
        ]
        self.transcript(silent)
        self.transcript(silent + [said("user", [{"type": "text", "text": "rename the widget file"}])], uuid=OTHER_UUID)
        found = self.scan()
        self.assertEqual((found[UUID].reason, found[OTHER_UUID].reason), ("no_operator_text", "eligible"))

    def test_scan_reads_duplicate_slug_session_once(self):
        self.transcript(spoken())
        larger = self.transcript(spoken() + spoken(OLD + timedelta(hours=1)), slug=OTHER_SLUG)
        found = [c for c in sources.scan(self.cfg, self.store, NOW) if c.uuid == UUID]
        self.assertEqual([(c.slug, c.path, c.reason) for c in found], [(OTHER_SLUG, larger, "eligible")])

    def test_scan_retries_held_under_three_then_skips(self):
        path = self.transcript(spoken())
        for holds, reason in ((1, "eligible"), (2, "eligible"), (3, "held")):
            self.store.record_session(UUID, SLUG, sha256(path), "held", reason="model_error")
            self.assertEqual((self.store.session(UUID)["holds"], self.scan()[UUID].reason), (holds, reason))
        self.transcript(spoken(OLD + timedelta(hours=1)), append=True)
        self.assertEqual(self.scan()[UUID].reason, "held")

    def test_scan_skips_artifacts_and_subagents(self):
        self.transcript(spoken())
        folder = self.tmp / "state/claude/projects" / SLUG
        for name in (f"{UUID}_box_20260110_Conflict.jsonl", f".{UUID}.jsonl.flakelab-tmp.42",
                     f"{UUID}.sync-conflict-20260110-120000-ABCDEFG.jsonl", "agent-1a2b3c4d.jsonl", "notes.txt"):
            (folder / name).write_text(json.dumps(said("user", "sort the widgets")) + "\n")
        (folder / UUID / "subagents").mkdir(parents=True)
        (folder / UUID / "subagents/agent-1a2b3c4d.jsonl").write_text(json.dumps(said("user", "sub task")) + "\n")
        found = sources.scan(self.cfg, self.store, NOW)
        self.assertEqual(sorted((c.reason, c.path.name) for c in found), [
            ("artifact", f".{UUID}.jsonl.flakelab-tmp.42"),
            ("artifact", f"{UUID}.sync-conflict-20260110-120000-ABCDEFG.jsonl"),
            ("artifact", f"{UUID}_box_20260110_Conflict.jsonl"),
            ("eligible", f"{UUID}.jsonl"),
        ])
        self.assertEqual({c.uuid for c in found}, {UUID})

    def test_scan_refuses_missing_state_root(self):
        with self.assertRaisesRegex(sources.SourceError, "^FLAKELAB_STATE_ROOT is not set$"):
            sources.scan(config.load({**self.env, "FLAKELAB_STATE_ROOT": ""}), self.store, NOW)
        with self.assertRaises(sources.SourceError) as caught:
            sources.scan(self.cfg, self.store, NOW)
        self.assertNotIn(str(self.tmp), str(caught.exception))


def call(*argv):
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        rc = cli.main(list(argv))
    return rc, out.getvalue(), err.getvalue()


def shim(*argv):
    return subprocess.run(["zsh", str(SHIM), *argv], capture_output=True, text=True, timeout=30, check=False)


class CliTest(unittest.TestCase):
    def test_cli_help_lists_subcommands(self):
        proc = shim("--help")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("usage: flakelab session-archive", proc.stdout)
        for name in ("run", "status", "review"):
            self.assertRegex(proc.stdout, rf"(?m)^ +{name} +\S")

    def test_cli_unknown_subcommand_exit_2(self):
        rc, out, err = call("bogus")
        self.assertEqual((rc, out), (2, ""))
        self.assertIn("invalid choice: 'bogus'", err)
        self.assertEqual(shim("bogus").returncode, 2)

    def test_cli_flags_parse_and_stubs_exit_0(self):
        for argv in (
            ["run"],
            ["run", "--session", UUID, "--dry-run", "--limit", "3", "--keep"],
            ["status"],
            ["status", "--json"],
            ["review"],
        ):
            with self.subTest(argv=argv):
                self.assertEqual(call(*argv)[0], 0)

    def test_cli_usage_errors_exit_2(self):
        for argv in (
            [],
            ["run", "--session"],
            ["run", "--session", "not-a-uuid"],
            ["run", "--limit", "x"],
            ["run", "--limit", "0"],
            ["review", "--json"],
            ["status", "--dry-run"],
        ):
            with self.subTest(argv=argv):
                rc, out, err = call(*argv)
                self.assertEqual((rc, out), (2, ""))
                self.assertIn("usage: flakelab session-archive", err)


if __name__ == "__main__":
    unittest.main(verbosity=2)
