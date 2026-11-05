"""Offline suite for `flakelab session-archive`: the shim and lib/session_archive/, run by test-session-archive."""

import contextlib
import copy
import dataclasses
from datetime import UTC, datetime, timedelta
import fcntl
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock
import urllib.error

from session_archive import archive, cards, cite, cli, config, pipeline, render, sources, store, summarize, windows
from session_archive import secrets as lane_secrets

LIB = Path(__file__).resolve().parent
SHIM = LIB.parent / "session-archive"
FIXTURE = Path(__file__).resolve().parent / "fixtures/session-archive/session-a.jsonl"
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

    def record(self, path, status, sha=None, **fields):
        """Record the session at path as the pipeline would: SHA, stat and last entry of the bytes as scanned."""
        stat = path.stat()
        fields.setdefault("last_entry", sources.last_entry(path))
        self.store.record_session(path.stem, path.parent.name, sha or sha256(path), status, size=stat.st_size,
                                  mtime=stat.st_mtime, **fields)

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
        stat = {"size": 4096, "mtime": 1768478400.25, "last_entry": None}
        self.store.record_session(UUID, SLUG, "a" * 64, "done", area="lab", card_hash="c1", archive_path="/srv/a.gz",
                                  **stat)
        later = {"size": 5000, "mtime": 1768478500.5, "last_entry": OLD}
        self.store.record_session(UUID, SLUG, "b" * 64, "held", reason="model_error", **later)
        self.store.record_session(UUID, SLUG, "b" * 64, "held", reason="unparsable", **later)
        row = self.store.session(UUID)
        self.assertEqual((row["status"], row["holds"], row["reason"], row["sha256"]), ("held", 2, "unparsable", "b" * 64))
        self.assertEqual((row["size"], row["mtime"], row["last_entry"]), (5000, 1768478500.5, OLD.isoformat()))
        self.assertEqual((row["area"], row["card_hash"], row["archive_path"]), ("lab", "c1", "/srv/a.gz"))
        self.assertEqual([r["uuid"] for r in self.store.held()], [UUID])
        self.store.record_session(UUID, SLUG, "b" * 64, "review", reason="unclear_area", **stat)
        self.assertEqual((self.store.session(UUID)["holds"], self.store.session(UUID)["last_entry"]), (2, None))
        self.store.record_session(UUID, SLUG, "b" * 64, "done", area="lab", card_hash="c2", archive_path="/srv/b.gz",
                                  **stat)
        self.assertEqual((self.store.session(UUID)["holds"], self.store.held()), (0, []))
        self.store.record_session(OTHER_UUID, SLUG, "c" * 64, "review", reason="unclear_area", **stat)
        self.assertEqual([r["uuid"] for r in self.store.review()], [OTHER_UUID])
        with self.assertRaises(ValueError):
            self.store.record_session(UUID, SLUG, "b" * 64, "finished", **stat)
        with self.assertRaises(TypeError):
            self.store.record_session(UUID, SLUG, "b" * 64, "done", size=1, mtime=1.0)

    def test_store_rejects_other_schema_version(self):
        self.assertEqual(self.store.db.execute("PRAGMA user_version").fetchone()[0], store.SCHEMA_VERSION)
        self.store.close()
        store.Store(self.cfg.state_dir / "state.sqlite3").close()
        for name, setup in (("unversioned.sqlite3", "CREATE TABLE sessions (uuid TEXT)"),
                            ("newer.sqlite3", "PRAGMA user_version = 7")):
            path = self.tmp / name
            db = sqlite3.connect(path)
            db.execute(setup)
            db.commit()
            db.close()
            with self.subTest(name=name), self.assertRaises(store.StoreError) as caught:
                store.Store(path)
            self.assertRegex(str(caught.exception), r"^the state database has schema version (0|7); this lane reads version 3:")
            self.assertNotIn(str(self.tmp), str(caught.exception))


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
        self.assertEqual((first.size, first.mtime), (path.stat().st_size, OLD.timestamp()))
        self.record(path, "done", area="lab")
        self.transcript(spoken(OLD + timedelta(hours=1)), append=True)
        grown = self.scan()[UUID]
        self.assertEqual((grown.reason, grown.sha256, grown.size), ("eligible", sha256(path), path.stat().st_size))
        self.assertNotEqual(grown.sha256, first.sha256)

    def test_scan_skips_unchanged(self):
        path = self.transcript(spoken())
        self.record(path, "done", area="lab")
        found = self.scan()[UUID]
        self.assertEqual((found.reason, found.sha256, found.last_entry), ("unchanged", sha256(path), OLD + timedelta(minutes=1)))
        os.utime(path, ((OLD + timedelta(hours=1)).timestamp(),) * 2)
        found = self.scan()[UUID]
        self.assertEqual((found.reason, found.sha256, found.last_entry), ("unchanged", sha256(path), OLD + timedelta(minutes=1)))

    def test_scan_reads_file_only_when_size_or_mtime_changed(self):
        path = self.transcript(spoken())
        self.record(path, "done", sha="f" * 64, area="lab", last_entry=OLD - timedelta(days=1))
        found = self.scan()[UUID]
        self.assertEqual((found.reason, found.sha256, found.last_entry), ("unchanged", "f" * 64, OLD - timedelta(days=1)))
        for status, reason in (("review", "review"), ("held", "eligible")):
            self.record(path, status, sha="f" * 64, reason="model_error")
            self.assertEqual((self.scan()[UUID].reason, self.scan()[UUID].sha256), (reason, "f" * 64))
        moved = OLD + timedelta(hours=1)
        os.utime(path, (moved.timestamp(), moved.timestamp()))
        self.assertEqual((self.scan()[UUID].reason, self.scan()[UUID].sha256), ("eligible", sha256(path)))
        self.record(path, "done", sha="f" * 64, area="lab")
        self.transcript(spoken(OLD + timedelta(hours=2)), append=True, modified=moved)
        self.assertEqual((self.scan()[UUID].reason, self.scan()[UUID].sha256), ("eligible", sha256(path)))

    def test_scan_orders_fast_path_retry_by_last_entry(self):
        held = self.transcript(spoken())
        self.record(held, "held", reason="model_error")
        self.transcript(spoken(OLD + timedelta(days=1)), uuid=OTHER_UUID)
        found = sources.scan(self.cfg, self.store, NOW)
        self.assertEqual([(c.uuid, c.reason, c.last_entry) for c in found], [
            (UUID, "eligible", OLD + timedelta(minutes=1)),
            (OTHER_UUID, "eligible", OLD + timedelta(days=1, minutes=1)),
        ])

    def test_scan_reports_unreadable_file_and_continues(self):
        if os.geteuid() == 0:
            self.skipTest("root reads a file of mode 000")
        areas = {"lab": {"description": "Lab work.", "library": str(self.tmp / "library"),
                         "projects": [SLUG, OTHER_SLUG, "-work-gamma"]}}
        cfg = config.load({**self.env, "SESSION_ARCHIVE_AREAS": json.dumps(areas)})
        locked = self.transcript(spoken())
        self.transcript(spoken(), uuid=OTHER_UUID)
        self.transcript(spoken(), uuid=THIRD_UUID, slug=OTHER_SLUG)
        unsearchable = self.transcript(spoken(), uuid=THIRD_UUID, slug="-work-gamma")
        for target, mode, kept in ((locked, 0, 0o644), (locked.parent.parent / OTHER_SLUG, 0, 0o755),
                                   (unsearchable.parent, 0o444, 0o755)):
            target.chmod(mode)
            self.addCleanup(target.chmod, kept)
        found = sources.scan(cfg, self.store, NOW)
        self.assertEqual([(c.uuid, c.slug, c.reason) for c in found], [
            (OTHER_UUID, SLUG, "eligible"), (UUID, SLUG, "unreadable"), ("", OTHER_SLUG, "unreadable"),
            (THIRD_UUID, "-work-gamma", "unreadable"),
        ])
        self.assertEqual((found[1].path, found[1].size, found[1].sha256), (locked, locked.stat().st_size, None))

    def test_scan_keeps_review_until_sha_changes(self):
        path = self.transcript(spoken())
        self.record(path, "review", reason="unclear_area")
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
            self.record(path, "held", reason="model_error")
            self.assertEqual((self.store.session(UUID)["holds"], self.scan()[UUID].reason), (holds, reason))
        os.utime(path, ((OLD + timedelta(hours=1)).timestamp(),) * 2)
        self.assertEqual(self.scan()[UUID].reason, "held")

    def test_scan_sha_change_resets_holds(self):
        path = self.transcript(spoken())
        for _ in range(3):
            self.record(path, "held", reason="model_error")
        self.assertEqual(self.scan()[UUID].reason, "held")
        self.transcript(spoken(OLD + timedelta(hours=1)), append=True)
        self.assertEqual((self.scan()[UUID].reason, self.scan()[UUID].sha256), ("eligible", sha256(path)))
        self.record(path, "held", reason="model_error")
        self.assertEqual((self.store.session(UUID)["holds"], self.scan()[UUID].reason), (1, "eligible"))
        self.transcript(spoken(OLD + timedelta(hours=2)), append=True)
        self.record(path, "review", reason="unclear_area")
        self.assertEqual(self.store.session(UUID)["holds"], 0)

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


FIXTURE_SPEAKERS = [
    (2, "OPERATOR"), (5, "ASSISTANT"), (5, "CALL(Read)"), (6, "RESULT(Read)"), (7, "CALL(Bash)"), (8, "RESULT(Bash)"),
    (10, "ASSISTANT"), (11, "OPERATOR"), (12, "OPERATOR"), (13, "CALL(Agent)"), (14, "RESULT(Agent)"), (15, "HANDBACK"),
    (16, "SYSTEM"), (17, "OPERATOR"), (18, "SYSTEM"), (19, "HANDBACK"), (21, "OPERATOR"), (22, "SYSTEM"), (24, "SYSTEM"),
    (25, "OPERATOR"), (26, "SYSTEM"), (27, "CALL(Bash)"), (28, "RESULT(Bash)"), (29, "ASSISTANT"), (30, "CALL(Bash)"),
    (31, "RESULT(Bash)"), (32, "ASSISTANT"), (33, "OPERATOR"), (34, "OPERATOR"), (36, "SYSTEM"), (37, "SYSTEM"),
    (38, "RESULT(?)"), (38, "OPERATOR"), (39, "OPERATOR"), (40, "ASSISTANT"),
]


def fixture_line(number):
    return json.loads(FIXTURE.read_bytes().split(b"\n")[number - 1])


def result_text(number):
    """The content of the one tool_result on that fixture line, flattened."""
    content = fixture_line(number)["message"]["content"][0]["content"]
    return content if isinstance(content, str) else "\n".join(block["text"] for block in content)


def record_at(rendered, line, speaker=None):
    return next(r for r in rendered.records if r.line == line and speaker in (None, r.speaker))


class RenderTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.path = Path(tmp.name) / f"{UUID}.jsonl"
        self.fixture = render.render(FIXTURE)

    def write(self, *lines):
        self.path.write_bytes(b"".join(line if isinstance(line, bytes) else json.dumps(line).encode() + b"\n"
                                       for line in lines))
        return self.path

    def test_render_anchors_every_record(self):
        done = self.fixture
        self.assertEqual([(r.line, r.speaker) for r in done.records], FIXTURE_SPEAKERS)
        self.assertEqual(done.text, "\n".join(r.rendered for r in done.records))
        for r in done.records:
            anchor = " ".join(part for part in (f"@L{r.line}", r.time, r.speaker) if part)
            self.assertEqual(r.rendered, f"{anchor}: {r.text}")
        self.assertEqual([record_at(done, line).time for line in (2, 5, 39)],
                         ["2026-01-10T09:00:00Z", "2026-01-10T09:01:00Z", ""])
        self.assertIn("\n@L39 OPERATOR: thanks, that is all\n", done.text)
        self.assertEqual((done.uuid, done.bytes_in), ("session-a", FIXTURE.stat().st_size))
        self.assertEqual(record_at(done, 5, "CALL(Read)").text, '{"file_path": "widgets/catalogue.txt"}')
        self.assertEqual(record_at(done, 38, "OPERATOR").text, "fill the gaps from shelf 9 first")
        self.assertNotIn("The task list changed", done.text)
        for line, speaker, start in (
            (8, "RESULT(Bash)", "[error] sort: cannot read"),
            (11, "OPERATOR", '[pasted] <pasted_content id="p1">'),
            (12, "OPERATOR", "[long; may relay another agent] \u273b Notes"),
            (15, "HANDBACK", "<task-notification>"),
            (18, "SYSTEM", '[peer session; not the operator] <agent-message from="shelf-planner">'),
            (24, "SYSTEM", "[compaction summary; generated, not evidence] This session"),
            (33, "OPERATOR", "[image]\nthis is the label layout"),
        ):
            with self.subTest(line=line):
                self.assertTrue(record_at(done, line, speaker).text.startswith(start), record_at(done, line).text[:80])

    def test_render_keeps_long_tool_result_whole(self):
        whole = result_text(6).strip()
        self.assertGreater(len(whole), 6_000)
        self.assertEqual(record_at(self.fixture, 6).text, whole)
        relayed = fixture_line(12)["message"]["content"]
        self.assertEqual(record_at(self.fixture, 12).text, f"[long; may relay another agent] {relayed}")
        call = record_at(self.fixture, 13).text
        self.assertEqual(json.loads(call), fixture_line(13)["message"]["content"][0]["input"])

    def test_render_cuts_only_records_over_max_record(self):
        whole = result_text(31).strip()
        self.assertGreater(len(whole.encode()), 60_000)
        [(line, chars)] = self.fixture.cuts
        record = record_at(self.fixture, 31)
        marker = f" [...{chars} chars cut...]"
        self.assertEqual(line, 31)
        self.assertTrue(record.text.endswith(marker))
        kept = record.text[:-len(marker)]
        self.assertEqual((whole[:len(kept)], len(kept) + chars), (kept, len(whole)))
        self.assertTrue(60_000 - 100 < len(record.rendered.encode()) <= 60_000)
        self.assertEqual([r for r in self.fixture.records if "chars cut...]" in r.text], [record])
        small = render.render(FIXTURE, max_record=2_000)
        self.assertEqual([line for line, _ in small.cuts], [6, 31])
        self.assertTrue(all(len(r.rendered.encode()) <= 2_000 for r in small.records))
        self.assertEqual([r for r in small.records if r.line not in (6, 31)],
                         [r for r in self.fixture.records if r.line not in (6, 31)])
        wide = render.render(self.write(said("assistant", [{"type": "text", "text": "\u00e4" * 100}])), max_record=120)
        [(_, chars)] = wide.cuts
        [record] = wide.records
        self.assertLessEqual(len(record.rendered.encode()), 120)
        self.assertEqual(record.text, "\u00e4" * (100 - chars) + f" [...{chars} chars cut...]")

    def test_render_skips_malformed_line(self):
        self.assertEqual(self.fixture.skipped_lines, 1)
        self.assertEqual([r.line for r in self.fixture.records if 8 <= r.line <= 10], [8, 10])
        path = self.write(said("user", "first prompt"), b"\n", b'{"type": "user", "mess\n', b"\x80\x81 not utf-8\n",
                          b"[1, 2]\n", b'"just a string"\n', said("user", "lone \ud83d half"),
                          {**said("user", "out of range"), "timestamp": "0001-01-01T00:00:00+01:00"},
                          said("assistant", [{"type": "text", "text": "last"}]), b'{"type": "assistant", "message"')
        broken = render.render(path)
        self.assertEqual(broken.skipped_lines, 5)
        self.assertEqual([(r.line, r.time, r.speaker, r.text) for r in broken.records], [
            (1, stamp(OLD), "OPERATOR", "first prompt"), (7, stamp(OLD), "OPERATOR", "lone \ufffd half"),
            (8, "", "OPERATOR", "out of range"), (9, stamp(OLD), "ASSISTANT", "last"),
        ])
        self.assertEqual((broken.bytes_in, broken.cuts), (path.stat().st_size, []))


class RedactTest(unittest.TestCase):
    # Invented values, assembled at run time so that no source line looks like a credential to the secrets scan.
    def test_redact_masks_key_shapes(self):
        pem = "\n".join(["-----BEGIN RSA " + "PRIVATE KEY-----", "M" * 64, "M" * 9, "-----END RSA " + "PRIVATE KEY-----"])
        cut_pem = "-----BEGIN OPENSSH " + "PRIVATE KEY-----\n" + "A" * 70 + "\n" + "A" * 9 + "\nexport PATH=/bin"
        heredoc = json.dumps({"command": "cat > k <<'EOF'\n" + cut_pem.split("\nexport")[0] + "\n" + "Z" * 30})
        for raw, masked in (
            ("key sk-ant-" + "a" * 24 + " in use", "key [REDACTED:anthropic] in use"),
            ('{"command": "echo\\nsk-ant-' + "a" * 12 + '"}', '{"command": "echo\\n[REDACTED:anthropic]"}'),
            ("key%3Dsk-ant-" + "a" * 12 + " <b>sk-proj-" + "o" * 20, "key%3D[REDACTED:anthropic] <b>[REDACTED:openai]"),
            ("GITLAB_TOKEN=glpat-" + "g" * 20 + " x=xglpat-" + "g" * 8,
             "GITLAB_TOKEN=[REDACTED:gitlab] x=x[REDACTED:gitlab]"),
            ("ghp_" + "h" * 36 + " github_pat_" + "h" * 40, "[REDACTED:github] [REDACTED:github]"),
            ("idgithub_pat_" + "h" * 20, "id[REDACTED:github]"),
            ("xoxb-" + "s" * 12 + " abcxoxp-" + "s" * 8, "[REDACTED:slack] abc[REDACTED:slack]"),
            ("id AKIA" + "Q" * 16, "id [REDACTED:aws]"),
            ("eyJ" + "a" * 10 + ".eyJ" + "b" * 10 + "." + "c" * 10, "[REDACTED:jwt]"),
            ("hvs." + "v" * 24, "[REDACTED:vault]"),
            (f"before\n{pem}\nafter", "before\n[REDACTED:pem]\nafter"),
            (cut_pem, "[REDACTED:pem]\nexport PATH=/bin"),
            (heredoc, """{"command": "cat > k <<'EOF'\\n[REDACTED:pem]"}"""),
            ('curl -H "Authorization: Bearer ' + "b" * 24 + '"', 'curl -H "Authorization: Bearer [REDACTED:bearer]"'),
            ('-H "Authorization: Basic ' + "Y" * 16 + '=="', '-H "Authorization: Basic [REDACTED:basic]"'),
            ('{"Authorization": "token ' + "f" * 40 + '"}', '{"Authorization": "token [REDACTED:auth-token]"}'),
            ("git clone https://deploy:" + "s" * 12 + "@git.example.invalid/w.git",
             "git clone https://deploy:[REDACTED:url]@git.example.invalid/w.git"),
            ("widgetctl login --password " + "p" * 9 + " --token '" + "t" * 8 + "'",
             "widgetctl login --password [REDACTED:flag] --token '[REDACTED:flag]'"),
            ("password=" + "p" * 12, "password=[REDACTED:assign]"),
            ('{"api_key": "' + "k" * 16 + '", "n": 1}', '{"api_key": "[REDACTED:assign]", "n": 1}'),
            ('{\\"db_password\\": \\"' + "p" * 10 + '\\"}', '{\\"db_password\\": \\"[REDACTED:assign]\\"}'),
            ('{"command": "PASSWORD=' + "h" * 9 + '\\ncurl x"}', '{"command": "PASSWORD=[REDACTED:assign]\\ncurl x"}'),
            ("client_secret: " + "c" * 8, "client_secret: [REDACTED:assign]"),
        ):
            with self.subTest(raw=raw):
                self.assertEqual(render.redact(raw), masked)
        for kept in ("token: abc1234", 'export BW_SESSION="${BW_SESSION_VALUE:-unset}"', "max_tokens: 16000",
                     f"run --session {UUID}", f"sessionId: {UUID}", "the secrets.env file", "keys start with sk-ant-",
                     "--token " + "t" * 7, '--token "$GITLAB_TOKEN" --password-file /run/pw', "ssh://git@host:22/repo"):
            with self.subTest(kept=kept):
                self.assertEqual(render.redact(kept), kept)
        done = render.render(FIXTURE)
        self.assertEqual(done.redactions, {"anthropic": 1, "assign": 2, "bearer": 1, "pem": 1})
        for raw in ("sk-ant-x", "b" * 24, "p" * 12, "A" * 16, "Q" * 8):
            self.assertNotIn(raw, done.text)

    def test_redact_masks_truncated_session_token(self):
        value = "Q" * 20
        for raw, masked in (
            (f"export BW_SESSION={value}", "export BW_SESSION=[REDACTED:assign]"),
            (f'export BW_SESSION="{value}', 'export BW_SESSION="[REDACTED:assign]'),
            (f'{{"command": "export BW_SESSION=\\"{value}', '{"command": "export BW_SESSION=\\"[REDACTED:assign]'),
            ("BW_SESSION=" + "Q" * 8, "BW_SESSION=[REDACTED:assign]"),
            ("BW_SESSION=" + "Q" * 7, "BW_SESSION=" + "Q" * 7),
            ("token: " + "t" * 8, "token: [REDACTED:assign]"),
            ("password=" + "p" * 7, "password=" + "p" * 7),
        ):
            with self.subTest(raw=raw):
                self.assertEqual(render.redact(raw), masked)
        result = record_at(render.render(FIXTURE), 28).text
        self.assertTrue(result.endswith("\n[REDACTED:pem]\nexport BW_SESSION=[REDACTED:assign]"), result)


class WindowsTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.tmp = Path(tmp.name)
        self.rendered = render.render(shutil.copy(FIXTURE, self.tmp / f"{UUID}.jsonl"))

    def members(self, window, number, total):
        """The indexes of the records a window holds, which must be whole and consecutive."""
        head, body = window.text.split("\n\n", 1)
        self.assertTrue(head.startswith(f"SESSION {UUID}\nWINDOW {number} of {total}; "
                                        f"records @L{window.start_line} to @L{window.end_line}. "), head)
        records = self.rendered.records
        found = [i for i, r in enumerate(records) if r.rendered in body]
        self.assertEqual(found, list(range(found[0], found[-1] + 1)))
        self.assertEqual(body, "\n".join(records[i].rendered for i in found))
        return found

    def test_windows_cover_every_record_once_or_overlap(self):
        records = self.rendered.records
        for size, overlap, count in ((60_000, 6_000, 3), (1_500, 500, None)):
            parts = windows.split(self.rendered, size=size, overlap=overlap)
            spans = [self.members(w, n, len(parts)) for n, w in enumerate(parts, 1)]
            with self.subTest(size=size):
                self.assertEqual([w.name for w in parts], [f"{UUID}.w{n}" for n in range(1, len(parts) + 1)])
                self.assertEqual(sorted(set().union(*spans)), list(range(len(records))))
                for window, span in zip(parts, spans):
                    first, last = records[span[0]], records[span[-1]]
                    self.assertEqual((window.start_line, window.end_line), (first.line, last.line))
                    body = len("\n".join(records[i].rendered for i in span).encode())
                    self.assertTrue(body <= size or len(span) == 1, (window.name, body))
                shared = []
                for before, after in zip(spans, spans[1:]):
                    common = [i for i in before if i in after]
                    self.assertEqual((common, after[:len(common)]), (before[len(before) - len(common):], common))
                    self.assertTrue(after[0] <= before[-1] + 1 and after[-1] > before[-1])
                    self.assertLessEqual(len("\n".join(records[i].rendered for i in common).encode()), overlap)
                    shared.append(len(common))
                if count:
                    self.assertEqual(len(parts), count)
                    self.assertEqual([records[i].line for i in spans[1]], [31])
                else:
                    self.assertTrue(any(shared), shared)
        (self.tmp / "empty.jsonl").write_text("\n")
        self.assertEqual(windows.split(render.render(self.tmp / "empty.jsonl")), [])


SUMMARY = {
    "what": "Sorted the widget catalogue by name.",
    "why": [{"text": "The operator asked for a sorted list.", "anchors": [2],
             "quotes": ["please sort the widget list"]}],
    "when": [], "how": [], "outcome": [],
    "open_ends": [{"text": "Shelf 9 gaps stay open.", "anchors": [38], "quotes": [], "as_of": "2026-01-10",
                   "tracked_in": "not tracked"}],
    "continue": [], "area": "lab",
}
API_USAGE = {"input_tokens": 1200, "output_tokens": 300, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0}
AREAS = config.load({"HOME": "/home/someone", "SESSION_ARCHIVE_AREAS": json.dumps({
    "lab": {"description": "Lab work.", "library": "/srv/library/lab", "projects": ["-a"]},
    "home": {"description": "Home\nmatters.", "library": "/srv/library/home", "projects": ["-b"]},
})})
AREAS_BLOCK = "lab: Lab work.\nhome: Home matters.\nunclear: none fits or the session spans two\n"


class Reply:
    """What urllib.request.urlopen returns: a context manager whose read() gives the body."""

    def __init__(self, body):
        self.body = json.dumps(body).encode()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def read(self, *args):
        return self.body


def api_reply(text, stop="end_turn", model="claude-haiku-5-5-20261001"):
    return Reply({"id": "msg_01", "type": "message", "role": "assistant", "model": model, "stop_reason": stop,
                  "content": [{"type": "thinking", "thinking": "", "signature": "sig"}, {"type": "text", "text": text}],
                  "usage": {**API_USAGE, "service_tier": "standard"}})


def http_error(code):
    body = io.BytesIO(b'{"type": "error", "error": {"message": "response body text"}}')
    return urllib.error.HTTPError("https://api.anthropic.com/v1/messages", code, "status", {}, body)


class Urlopen:
    """Stands in for urllib.request.urlopen: records each request and plays the outcomes in order."""

    def __init__(self, *outcomes):
        self.outcomes, self.requests = list(outcomes), []

    def __call__(self, request, timeout=None):
        self.requests.append((request, timeout))
        outcome = self.outcomes.pop(0)
        if isinstance(outcome, BaseException):
            raise outcome
        return outcome


class TransportTest(unittest.TestCase):
    def complete(self, *outcomes, key="lane-test-key", model="claude-haiku-5-5", **options):
        fake, waits = Urlopen(*outcomes), []
        transport = summarize.ApiTransport(key, sleep=waits.append)
        with mock.patch("urllib.request.urlopen", fake):
            done = transport.complete("SYSTEM TEXT", "WINDOW TEXT", {"type": "object"}, model, "low", **options)
        return done, fake.requests, waits

    def test_api_transport_builds_request_shape(self):
        done, [(request, timeout)], waits = self.complete(api_reply(json.dumps(SUMMARY)))
        self.assertEqual((request.full_url, request.get_method()), ("https://api.anthropic.com/v1/messages", "POST"))
        self.assertEqual({name.lower(): value for name, value in request.header_items()}, {
            "x-api-key": "lane-test-key", "anthropic-version": "2023-06-01", "content-type": "application/json"})
        self.assertEqual(json.loads(request.data), {
            "model": "claude-haiku-5-5", "max_tokens": 16000, "system": "SYSTEM TEXT", "thinking": {"type": "adaptive"},
            "output_config": {"effort": "low", "format": {"type": "json_schema", "schema": {"type": "object"}}},
            "messages": [{"role": "user", "content": "WINDOW TEXT"}],
        })
        self.assertGreater(timeout, 0)
        self.assertEqual(waits, [])
        self.assertEqual(done, summarize.Completion(SUMMARY, API_USAGE, done.usd, "claude-haiku-5-5-20261001",
                                                    "end_turn", None))
        self.assertAlmostEqual(done.usd, (1200 * 0.10 + 300 * 0.50) / 1e6)
        _, [(request, _)], _ = self.complete(api_reply("{}"), max_tokens=2000)
        self.assertEqual(json.loads(request.data)["max_tokens"], 2000)
        cut, _, _ = self.complete(api_reply('{"what": "Sorted', stop="max_tokens"))
        self.assertEqual((cut.parsed, cut.usage, cut.stop_reason, cut.error),
                         (None, API_USAGE, "max_tokens", "stop_reason max_tokens"))
        self.assertGreater(cut.usd, 0)
        for text in ("not json {", "[1, 2]"):
            garbled, _, _ = self.complete(api_reply(text))
            self.assertEqual((garbled.parsed, garbled.error), (None, summarize.UNPARSABLE))
        with self.assertRaisesRegex(summarize.UnknownModel, "^no list price for model claude-unknown-1$"):
            self.complete(model="claude-unknown-1")

    def test_api_transport_retries_429_then_succeeds(self):
        done, requests, waits = self.complete(http_error(429), api_reply(json.dumps(SUMMARY)))
        self.assertEqual((len(requests), waits, done.parsed, done.error), (2, [20], SUMMARY, None))
        self.assertEqual(requests[0][0].data, requests[1][0].data)
        refused = urllib.error.URLError(ConnectionRefusedError(111, "Connection refused"))
        done, requests, waits = self.complete(http_error(529), refused, TimeoutError("timed out"), http_error(500))
        self.assertEqual((len(requests), waits), (4, [20, 40, 60]))
        self.assertEqual((done.parsed, done.usd, done.stop_reason, done.error), (None, 0.0, None, "http 500"))
        self.assertEqual(done.usage, dict.fromkeys(API_USAGE, 0))
        done, requests, _ = self.complete(refused, refused, refused, refused)
        self.assertEqual((len(requests), done.error), (4, "network ConnectionRefusedError"))
        for code in (400, 401, 403, 404, 413):
            with self.subTest(code=code):
                done, requests, waits = self.complete(http_error(code))
                self.assertEqual((len(requests), waits, done.error), (1, [], f"http {code}"))

    def test_api_transport_keeps_key_and_bodies_out_of_errors(self):
        key = "lane-key-" + "k" * 24
        done, _, _ = self.complete(http_error(400), key=key)
        garbled, _, _ = self.complete(Reply("not a message"), key=key)
        for text in (done.error, garbled.error, repr(done), repr(summarize.ApiTransport(key))):
            self.assertNotIn(key, text)
            self.assertNotIn("response body text", text)
        self.assertEqual(garbled.error, "response is not a message")
        for bad in ("lane-key\nInjected: 1", "lane key", ""):
            with self.subTest(bad=bad), self.assertRaises(ValueError) as caught:
                summarize.ApiTransport(bad)
            self.assertEqual(str(caught.exception), f"{lane_secrets.KEY} is not a value an HTTP header can carry")

    def test_price_haiku_example(self):
        million = {"input_tokens": 1_000_000, "output_tokens": 1_000_000}
        self.assertAlmostEqual(summarize.price(million, "claude-haiku-5-5"), 0.60)
        self.assertAlmostEqual(summarize.price(million, "claude-haiku-5-5-20261001"), 0.60)
        self.assertAlmostEqual(summarize.price(million, "claude-sonnet-5-5"), 12.0)
        self.assertAlmostEqual(summarize.price(million, "claude-opus-5-5"), 24.0)
        cached = {"input_tokens": 200_000, "cache_creation_input_tokens": 300_000, "cache_read_input_tokens": 500_000}
        self.assertAlmostEqual(summarize.price(cached, "claude-haiku-5-5"), 0.10)
        self.assertEqual(summarize.price({}, "claude-opus-5-5"), 0.0)
        for unknown in ("claude-unknown-1", "claude-haiku-5-5-preview", "claude-haiku-5"):
            with self.subTest(model=unknown), self.assertRaises(summarize.UnknownModel):
                summarize.price(million, unknown)


class PromptTest(unittest.TestCase):
    def test_system_prompt_appends_areas_block(self):
        self.assertEqual(summarize.system_prompt("Summarize.\n\n## Areas\n", AREAS.areas),
                         f"Summarize.\n\n## Areas\n\n{AREAS_BLOCK}")
        self.assertEqual(summarize.system_prompt("Summarize.\n\n## Areas", {}),
                         "Summarize.\n\n## Areas\n\nunclear: none fits or the session spans two\n")
        fields = json.loads(summarize.asset(summarize.SCHEMA))["properties"]
        for name in (summarize.SYSTEM, summarize.MERGE):
            base = summarize.asset(name)
            with self.subTest(asset=name):
                self.assertTrue(base.endswith("\n## Areas\n"), base[-80:])
                self.assertEqual(base.count("## Areas"), 1)
                self.assertEqual(summarize.system_prompt(base, AREAS.areas), f"{base}\n{AREAS_BLOCK}")
                for word in ("@L", "verbatim", "anchors", "quotes"):
                    self.assertIn(word, base)
        system = summarize.asset(summarize.SYSTEM)
        for field in fields:
            self.assertIn(f"`{field}`", system)

    def test_schema_area_enum(self):
        base = json.loads(summarize.asset(summarize.SCHEMA))
        shaped = summarize.schema(base, AREAS.areas)
        self.assertEqual(shaped["properties"]["area"], {"type": "string", "enum": ["lab", "home", "unclear"]})
        self.assertEqual(base["properties"]["area"], {"type": "string"})
        self.assertEqual(summarize.schema(base, {})["properties"]["area"]["enum"], ["unclear"])
        self.assertEqual(list(base["properties"]),
                         ["what", "why", "when", "how", "outcome", "open_ends", "continue", "area"])
        item = {"text": {"type": "string"}, "anchors": {"type": "array", "items": {"type": "integer"}},
                "quotes": {"type": "array", "items": {"type": "string"}}}
        for name in ("why", "when", "how", "outcome", "continue"):
            self.assertEqual(base["properties"][name]["items"]["properties"], item)
        self.assertEqual(base["properties"]["open_ends"]["items"]["properties"],
                         {**item, "as_of": {"type": "string"}, "tracked_in": {"type": "string"}})
        objects = [base]
        while objects:
            node = objects.pop()
            if node.get("type") == "object":
                self.assertEqual((node["additionalProperties"], node["required"]), (False, list(node["properties"])))
            objects.extend(child for child in (*node.get("properties", {}).values(), node.get("items")) if child)
        self.assertTrue(summarize.conforms(SUMMARY, shaped))
        for bad in ({**SUMMARY, "area": "elsewhere"}, {**SUMMARY, "extra": 1}, {**SUMMARY, "why": [{"text": "x"}]},
                    {**SUMMARY, "why": [{"text": "x", "anchors": ["2"], "quotes": []}]},
                    {**SUMMARY, "why": [{"text": "x", "anchors": [True], "quotes": []}]}):
            self.assertFalse(summarize.conforms(bad, shaped), bad)


class SummarizeTest(unittest.TestCase):
    def setUp(self):
        self.cfg = AREAS
        self.charged = []
        self.shape = summarize.schema(json.loads(summarize.asset(summarize.SCHEMA)), self.cfg.areas)
        [self.first, *_] = windows.split(render.render(FIXTURE))

    def test_window_returns_parsed_or_raises_on_unparsable(self):
        failed = summarize.Completion(None, dict.fromkeys(API_USAGE, 0), 0.0, "claude-haiku-5-5", None, "http 500")
        stub = summarize.StubTransport([SUMMARY, "not json {", {**SUMMARY, "area": "elsewhere"},
                                        {k: v for k, v in SUMMARY.items() if k != "continue"}, failed])
        self.assertEqual(summarize.window(stub, self.cfg, self.first, self.cfg.areas, charge=self.charged.append),
                         SUMMARY)
        [call] = stub.calls
        self.assertEqual(call["user"], f"{self.first.text}\n\n{summarize.WINDOW_TAIL}")
        self.assertEqual((call["user"].count("\nWINDOW "), call["user"].startswith("SESSION session-a\nWINDOW 1 of")),
                         (1, True))
        self.assertEqual(call["system"], summarize.system_prompt(summarize.asset(summarize.SYSTEM), self.cfg.areas))
        self.assertEqual(call["schema"], self.shape)
        self.assertEqual((call["model"], call["effort"], call["max_tokens"]), ("claude-haiku-5-5", "low", 16000))
        for reason in ("unparsable", "unparsable", "unparsable", "model_error"):
            with self.subTest(reason=reason), self.assertRaises(summarize.SummarizeError) as caught:
                summarize.window(stub, self.cfg, self.first, self.cfg.areas, charge=self.charged.append)
            self.assertEqual(caught.exception.reason, reason)
        self.assertEqual(str(caught.exception), "model_error: http 500")
        self.assertEqual(len(self.charged), 5)
        self.assertEqual(self.charged[0], summarize.Completion(SUMMARY, summarize.STUB_USAGE, self.charged[0].usd,
                                                               "claude-haiku-5-5", "end_turn", None))
        self.assertGreater(self.charged[0].usd, 0)
        with self.assertRaisesRegex(RuntimeError, "no response left"):
            summarize.window(stub, self.cfg, self.first, self.cfg.areas)

    def test_merge_skips_single_window(self):
        stub = summarize.StubTransport([])
        self.assertIs(summarize.merge(stub, self.cfg, [SUMMARY], self.cfg.areas, charge=self.charged.append), SUMMARY)
        self.assertEqual((stub.calls, self.charged), ([], []))
        later = {**SUMMARY, "what": "Relabelled shelf 9.", "area": "home"}
        merged = {**SUMMARY, "what": "Sorted the catalogue and relabelled shelf 9."}
        stub = summarize.StubTransport([merged])
        self.assertEqual(summarize.merge(stub, self.cfg, [SUMMARY, later], self.cfg.areas, charge=self.charged.append),
                         merged)
        [call] = stub.calls
        self.assertEqual(call["system"], summarize.system_prompt(summarize.asset(summarize.MERGE), self.cfg.areas))
        self.assertEqual(call["schema"], self.shape)
        parts = [json.dumps(part, ensure_ascii=False) for part in (SUMMARY, later)]
        self.assertEqual(call["user"], f"PART 1 of 2\n{parts[0]}\n\nPART 2 of 2\n{parts[1]}\n\n{summarize.MERGE_TAIL}")
        self.assertEqual(len(self.charged), 1)
        with self.assertRaises(summarize.SummarizeError):
            summarize.merge(summarize.StubTransport(["[]"]), self.cfg, [SUMMARY, later], self.cfg.areas)
        with self.assertRaisesRegex(ValueError, "no window summaries"):
            summarize.merge(stub, self.cfg, [], self.cfg.areas)

    def whats(self, call):
        return re.findall(r'"what": "([^"]*)"', call["user"])

    def test_merge_groups_parts_under_input_bound(self):
        parts = [{**SUMMARY, "what": f"Window {n} sorted shelf {n}."} for n in range(12)]
        system = summarize.system_prompt(summarize.asset(summarize.MERGE), self.cfg.areas)
        size = summarize.estimate(json.dumps(parts[0], ensure_ascii=False))
        answers = [{**SUMMARY, "what": f"Group {n}."} for n in range(3)] + [{**SUMMARY, "what": "The session."}]
        stub = summarize.StubTransport(answers)
        # Room for four parts a group: three groups, then their three answers in one more call.
        with mock.patch.object(summarize, "MERGE_INPUT_TOKENS", summarize.merge_overhead(system) + 4.5 * size):
            merged = summarize.merge(stub, self.cfg, parts, self.cfg.areas, charge=self.charged.append)
        self.assertEqual((merged["what"], len(stub.calls), len(self.charged)), ("The session.", 4, 4))
        self.assertEqual([self.whats(call) for call in stub.calls], [
            *([f"Window {n} sorted shelf {n}." for n in range(first, first + 4)] for first in (0, 4, 8)),
            ["Group 0.", "Group 1.", "Group 2."]])
        self.assertEqual([call["user"].split("\n")[0] for call in stub.calls], ["PART 1 of 4"] * 3 + ["PART 1 of 3"])
        self.assertEqual({call["max_tokens"] for call in stub.calls}, {summarize.MERGE_MAX_TOKENS})
        self.assertEqual(summarize.MERGE_MAX_TOKENS, 32_000)

    def test_merge_retries_max_tokens_by_splitting(self):
        parts = [{**SUMMARY, "what": f"Window {n}."} for n in range(4)]
        cut = summarize.completion('{"what": "Sorted', "max_tokens", summarize.STUB_USAGE, "claude-haiku-5-5",
                                   "claude-haiku-5-5")
        halves = [{**SUMMARY, "what": "Windows 0 and 1."}, {**SUMMARY, "what": "Windows 2 and 3."}]
        stub = summarize.StubTransport([cut, *halves, {**SUMMARY, "what": "The session."}])
        merged = summarize.merge(stub, self.cfg, parts, self.cfg.areas, charge=self.charged.append)
        self.assertEqual([self.whats(call) for call in stub.calls], [
            [f"Window {n}." for n in range(4)], ["Window 0.", "Window 1."], ["Window 2.", "Window 3."],
            ["Windows 0 and 1.", "Windows 2 and 3."]])
        self.assertEqual((merged["what"], len(self.charged), self.charged[0].stop_reason),
                         ("The session.", 4, "max_tokens"))
        # Once only: a half cut again, or a pair that halves into single parts, holds the session.
        for answers, given, calls in (([cut, cut], parts, 2), ([cut], parts[:2], 1)):
            stub = summarize.StubTransport(answers)
            with self.subTest(parts=len(given)), self.assertRaises(summarize.SummarizeError) as caught:
                summarize.merge(stub, self.cfg, given, self.cfg.areas)
            self.assertEqual((caught.exception.reason, caught.exception.detail, len(stub.calls)),
                             ("model_error", "stop_reason max_tokens", calls))

    def test_projection_counts_grouped_merge_calls(self):
        self.assertEqual([summarize.merge_calls(count, 4_000, 750) for count in (1, 2, 9, 10, 109)], [0, 1, 1, 2, 15])
        per_input, per_output = summarize.rates("claude-haiku-5-5")
        merge_call = summarize.MERGE_INPUT_TOKENS * per_input + summarize.MERGE_OUTPUT_TOKENS * per_output
        fixture = windows.split(render.render(FIXTURE))
        window_call = max(len(w.text.encode()) for w in fixture) / 3.5 * per_input + 4_000 * per_output
        self.assertAlmostEqual(pipeline.projected(self.cfg, fixture), (3 * window_call + merge_call) / 1e6)
        [single] = fixture[2:]
        self.assertAlmostEqual(pipeline.projected(self.cfg, [single]),
                               (len(single.text.encode()) / 3.5 * per_input + 4_000 * per_output) / 1e6)


class BudgetTest(Scratch):
    def test_budget_denies_above_cap(self):
        run, other = self.store.start_run(), self.store.start_run()
        budget = summarize.Budget(self.store, run, 0.5)
        self.assertTrue(budget.allow())
        budget.charge(UUID, "claude-haiku-5-5", API_USAGE, 0.25)
        self.assertTrue(budget.allow())
        budget.charge(OTHER_UUID, "claude-haiku-5-5-20261001", API_USAGE, 0.25)
        self.assertFalse(budget.allow())
        budget.charge(OTHER_UUID, "claude-haiku-5-5", API_USAGE, 0.25)
        self.assertFalse(budget.allow())
        rows = self.store.db.execute("SELECT uuid, model_id, usage, usd FROM ledger WHERE run_id = ? ORDER BY rowid",
                                     (run,)).fetchall()
        self.assertEqual([(r["uuid"], r["model_id"], json.loads(r["usage"]), r["usd"]) for r in rows][:2], [
            (UUID, "claude-haiku-5-5", API_USAGE, 0.25), (OTHER_UUID, "claude-haiku-5-5-20261001", API_USAGE, 0.25)])
        self.assertTrue(summarize.Budget(self.store, other, 0.5).allow())
        self.assertFalse(summarize.Budget(self.store, other, 0).allow())


def item(text, anchors, *quotes, **extra):
    return {"text": text, "anchors": anchors, "quotes": list(quotes), **extra}


def summary_of(**lists):
    empty = dict.fromkeys(("why", "when", "how", "outcome", "open_ends", "continue"), [])
    return {"what": "Sorted the widget catalogue.", **empty, "area": "lab", **lists}


def blot(text, *positions):
    return "".join("#" if i in positions else c for i, c in enumerate(text))


ARCHIVED = f"/srv/archive/{SLUG}/{UUID}.0123abcd.jsonl.gz"
LOCAL = f"/srv/state/claude/projects/{SLUG}/{UUID}.jsonl"
CARD_META = cards.CardMeta(UUID, SLUG, "lab", Path(ARCHIVED), "ab" * 32, 4096, Path(LOCAL), "claude-haiku-5-5", "low",
                           "2026-01-20")
CARD_SUMMARY = summary_of(
    what="Sorted the widget catalogue\nby name  and kept a backup.",
    why=[item("The operator asked for a sorted catalogue.", [2], "Sort the widget catalogue by name", verified=True)],
    when=[item("2026-01-10 09:00 the sort started.", [2, 5], verified=True)],
    how=[item("Took the shelf\nnotes from a relayed list.", [12], "- shelf 1 holds batch 1\n- shelf 2 holds batch 2",
              verified=True)],
    open_ends=[item("Shelf 9 gaps stay open.", [38], "fill the gaps from shelf 9 first", as_of="2026-01-10",
                    tracked_in="not tracked", verified=True)],
    **{"continue": [item("The catalogue is widgets/catalogue.txt.", [5], "widgets/catalogue.txt", verified=True)]},
)
CARD_TEXT = f"""# Session {UUID}

## What

Sorted the widget catalogue by name and kept a backup.

## Why

- The operator asked for a sorted catalogue. @L2
  > "Sort the widget catalogue by name"

## When

- 2026-01-10 09:00 the sort started. @L2,@L5

## How

- Took the shelf notes from a relayed list. @L12
  > "- shelf 1 holds batch 1
  > - shelf 2 holds batch 2"

## Outcome

None.

## Open ends

- Shelf 9 gaps stay open. @L38
  as of 2026-01-10
  > "fill the gaps from shelf 9 first"

## What an agent needs to continue

- The catalogue is widgets/catalogue.txt. @L5
  > "widgets/catalogue.txt"

## Pointer

Archive: {ARCHIVED}
SHA-256: {"ab" * 32}
Bytes: 4096
Fetch: zcat '{ARCHIVED}'
Local (until cleanup): {LOCAL}
Project: {SLUG}
Area: lab
Recipe: session-archive-v1
Model: claude-haiku-5-5/low
Extracted: 2026-01-20
"""


class CiteTest(unittest.TestCase):
    def setUp(self):
        self.fixture = render.render(FIXTURE)

    def test_cite_marks_exact_quote_verified(self):
        given = summary_of(
            why=[item("The operator asked for a sorted catalogue.", [2, 2, 1, 9, 999, 0, -2],
                      "Sort the widget catalogue by name")],
            how=[item("Read the catalogue.", [5], "widgets/catalogue.txt"),
                 item("Quotes from two anchors.", [2, 40], "keep the old order", "the backup is kept")],
            outcome=[item("The session finished.", [40])],
            open_ends=[item("Shelf 9 gaps stay open.", [38], "fill the gaps from shelf 9 first", "3 gaps on shelf 4",
                            as_of="2026-01-10", tracked_in="not tracked")],
        )
        before = copy.deepcopy(given)
        done = cite.check(given, self.fixture)
        self.assertEqual(given, before)
        self.assertEqual(list(done), list(given))
        self.assertEqual((done["what"], done["area"], done["when"], done["continue"]), (given["what"], "lab", [], []))
        self.assertEqual(done["why"], [{**given["why"][0], "anchors": [2], "verified": True}])
        for name in ("how", "outcome", "open_ends"):
            with self.subTest(section=name):
                self.assertEqual(done[name], [{**entry, "verified": True} for entry in given[name]])

    def test_cite_accepts_fuzzy_quote(self):
        operator = record_at(self.fixture, 2).text
        dump = record_at(self.fixture, 31).text
        middle = dump[len(dump) // 2:len(dump) // 2 + 300]
        drifted = middle.replace("colour", "color")
        flattened = "- shelf 1 holds batch 1 - shelf 2 holds batch 2"
        for quote in (drifted, flattened, "Sort the widget catalog by name and keep the old order"):
            self.assertFalse(any(quote in r.text for r in self.fixture.records), quote)
        cases = [(item("Typo.", [2], "Sort the widget catalog by name and keep the old order"), True),
                 (item("Newlines read as spaces.", [12], flattened), True),
                 (item("Long record, drifted slice.", [31], drifted), True),
                 (item("Three of twenty characters off.", [2], blot(operator[:20], 2, 9, 17)), True),
                 (item("Four of twenty characters off.", [2], blot(operator[:20], 2, 7, 12, 17)), False),
                 (item("Longer than its short record.", [17], "also drop the duplicates, then sort the rest again"),
                  False)]
        done = cite.check(summary_of(how=[entry for entry, _ in cases]), self.fixture)
        self.assertEqual([(entry["text"], entry["verified"]) for entry in done["how"]],
                         [(entry["text"], verified) for entry, verified in cases])

    def test_cite_marks_missing_quote_unverified(self):
        given = summary_of(outcome=[
            item("An invented fact.", [2], "Sort the widget catalogue", "the shelves were repainted blue"),
            item("A quote from a record no anchor names.", [2], "fill the gaps from shelf 9 first"),
            item("An empty quote.", [2], ""),
            item("Anchors that name no record.", [1, 9, 999]),
            item("No anchors.", []),
        ])
        done = cite.check(given, self.fixture)
        self.assertEqual([(entry["anchors"], entry["quotes"], entry["verified"]) for entry in done["outcome"]], [
            ([2], ["Sort the widget catalogue", "the shelves were repainted blue"], False),
            ([2], ["fill the gaps from shelf 9 first"], False), ([2], [""], False), ([], [], False), ([], [], False),
        ])
        card = cards.render(CARD_META, done)
        self.assertIn('\n- An invented fact. (unverified) @L2\n  > "Sort the widget catalogue"\n'
                      '  > "the shelves were repainted blue"\n', card)
        self.assertIn("\n- Anchors that name no record. (unverified)\n- No anchors. (unverified)\n", card)

    def test_cite_normalises_typographic_drift(self):
        said = ["don't move the gamma brackets", "the label says “shelf 7”", "merged MR !12 today",
                "keep the old\n  order in a backup"]
        records = [render.Record(line, "", "OPERATOR", text) for line, text in enumerate(said, 1)]
        cases = [(item("A curly apostrophe.", [1], "don’t"), True),
                 (item("Straight quotes for curly ones.", [2], '"shelf 7"'), True),
                 (item("A non-breaking space.", [3], "MR !12"), True),
                 (item("Whitespace folded.", [4], " old order  in a\tbackup "), True),
                 (item("Drift and a typo.", [1], "don’t  move the gama brackets"), True),
                 (item("Still invented.", [1], "don’t paint the shelves"), False),
                 (item("Blank once folded.", [1], "  \n"), False)]
        rendered = render.Rendered("", records, [], 0, 0, UUID, {})
        done = cite.check(summary_of(how=[entry for entry, _ in cases]), rendered)
        self.assertEqual([(entry["text"], entry["verified"]) for entry in done["how"]],
                         [(entry["text"], verified) for entry, verified in cases])
        self.assertEqual([entry["quotes"] for entry in done["how"]], [entry["quotes"] for entry, _ in cases])


class CardTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.library = Path(tmp.name) / "library"
        self.library.mkdir()

    def test_card_sections_in_spec_order(self):
        card = cards.render(CARD_META, CARD_SUMMARY)
        self.assertEqual(re.findall(r"(?m)^#+ (.*)$", card), [
            f"Session {UUID}", "What", "Why", "When", "How", "Outcome", "Open ends", "What an agent needs to continue",
            "Pointer"])
        self.assertEqual(card, CARD_TEXT)
        self.assertEqual(cards.render(CARD_META, {**CARD_SUMMARY, "what": " "}).split("\n## Why")[0],
                         f"# Session {UUID}\n\n## What\n\nNone.\n")

    def test_card_escapes_block_markers(self):
        sections = [f"Session {UUID}", "What", "Why", "When", "How", "Outcome", "Open ends",
                    "What an agent needs to continue", "Pointer"]
        fenced = item("```sh", [2], "```", "## not a heading", verified=True)
        card = cards.render(CARD_META, summary_of(what="## Pointer", why=[fenced]))
        self.assertEqual(re.findall(r"(?m)^#+ (.*)$", card), sections)
        self.assertIn('\n## What\n\n\\## Pointer\n\n## Why\n\n- \\```sh @L2\n  > "```"\n  > "## not a heading"\n\n',
                      card)
        for text, shown in (("# Session evil", "\\# Session evil"), ("<!-- note", "\\<!-- note"), ("~~~", "\\~~~"),
                            ("> relayed", "\\> relayed"), ("| a | b |", "\\| a | b |"), ("* x", "\\* x"),
                            ("+ x", "\\+ x"), ("- x", "\\- x"), ("___", "\\___"), ("1. first", "1\\. first"),
                            ("12) next", "12\\) next"), ("  ## indented", "\\## indented"),
                            ("2026-01-10 sorted", "2026-01-10 sorted"), ("Sorted #1 - done", "Sorted #1 - done")):
            with self.subTest(text=text):
                card = cards.render(CARD_META, summary_of(what=text, outcome=[item(text, [2], "q", verified=True)]))
                self.assertEqual(re.findall(r"(?m)^#+ (.*)$", card), sections)
                self.assertIn(f"\n## What\n\n{shown}\n\n", card)
                self.assertIn(f'\n## Outcome\n\n- {shown} @L2\n  > "q"\n\n', card)

    def test_card_pointer_labels_verbatim(self):
        odd = "/srv/archive/it's here/one.jsonl.gz"
        card = cards.render(dataclasses.replace(CARD_META, archive_path=odd), CARD_SUMMARY)
        self.assertEqual(card.split("\n## Pointer\n\n")[1].splitlines(), [
            f"Archive: {odd}", f"SHA-256: {'ab' * 32}", "Bytes: 4096",
            "Fetch: zcat '/srv/archive/it'\\''s here/one.jsonl.gz'", f"Local (until cleanup): {LOCAL}",
            f"Project: {SLUG}", "Area: lab", "Recipe: session-archive-v1", "Model: claude-haiku-5-5/low",
            "Extracted: 2026-01-20"])
        fetch = next(line for line in card.splitlines() if line.startswith("Fetch: "))
        self.assertEqual(shlex.split(fetch.removeprefix("Fetch: ")), ["zcat", odd])

    def test_card_unverified_suffix(self):
        for entry, line in (
            (item("Sorted.", [2, 5], verified=True), "- Sorted. @L2,@L5\n"),
            (item("Sorted.", [2, 5], verified=False), "- Sorted. (unverified) @L2,@L5\n"),
            (item("Sorted.", [2, 5]), "- Sorted. (unverified) @L2,@L5\n"),
            (item("Sorted.", [], "Sort the widget", verified=False), '- Sorted. (unverified)\n  > "Sort the widget"\n'),
        ):
            with self.subTest(entry=entry):
                outcome = cards.render(CARD_META, summary_of(outcome=[entry])).split("## Outcome\n\n")[1]
                self.assertTrue(outcome.startswith(line), outcome)
        gap = item("Gaps stay open.", [38], as_of="2026-01-10", tracked_in="plan file", verified=False)
        card = cards.render(CARD_META, summary_of(open_ends=[gap]))
        self.assertIn("\n- Gaps stay open. (unverified) @L38\n  as of 2026-01-10, tracked in plan file\n\n", card)

    def test_card_open_end_omits_empty_tracking(self):
        cases = [(" 2026-01-10 ", " MR !12 ", "  as of 2026-01-10, tracked in MR !12\n")]
        cases += [("2026-01-10", ref, "  as of 2026-01-10\n")
                  for ref in ("", "  ", "None", "NOT TRACKED", " n/a ", "-", "Not\ntracked")]
        cases += [(" ", "issue #4", "  tracked in issue #4\n"), ("", "not tracked", ""), ("", "", "")]
        for as_of, tracked_in, detail in cases:
            with self.subTest(as_of=as_of, tracked_in=tracked_in):
                gap = item("Gaps stay open.", [38], "3 gaps on shelf 4", as_of=as_of, tracked_in=tracked_in,
                           verified=True)
                card = cards.render(CARD_META, summary_of(open_ends=[gap]))
                self.assertIn(f'\n- Gaps stay open. @L38\n{detail}  > "3 gaps on shelf 4"\n\n', card)

    def files(self):
        return sorted(path.name for path in self.library.iterdir())

    def test_card_write_is_idempotent(self):
        (self.library / "card-older-recipe.md").write_text("kept\n")
        card = cards.render(CARD_META, CARD_SUMMARY)
        path, digest, written = cards.write(self.library, UUID, card)
        self.assertEqual((path, written), (self.library / f"session-{UUID}.md", True))
        self.assertEqual(path.read_text(), card)
        later = cards.render(dataclasses.replace(CARD_META, extracted="2026-02-01"), CARD_SUMMARY)
        self.assertNotEqual(later, card)
        self.assertEqual(cards.write(self.library, UUID, card), (path, digest, False))
        self.assertEqual(cards.write(self.library, UUID, later), (path, digest, False))
        self.assertEqual(path.read_text(), card)
        grown = cards.render(dataclasses.replace(CARD_META, bytes=8192, extracted="2026-02-01"), CARD_SUMMARY)
        moved, regrown, written = cards.write(self.library, UUID, grown)
        self.assertEqual((moved, written, path.read_text()), (path, True, grown))
        self.assertNotEqual(regrown, digest)
        self.assertEqual(cards.write(self.library, UUID, grown), (path, regrown, False))
        self.assertEqual(cards.write(self.library, OTHER_UUID, card)[1:], (digest, True))
        self.assertEqual(self.files(),
                         sorted(["card-older-recipe.md", f"session-{OTHER_UUID}.md", f"session-{UUID}.md"]))

    def test_card_write_is_atomic(self):
        mask = os.umask(0o027)
        self.addCleanup(os.umask, mask)
        old, new = (cards.render(dataclasses.replace(CARD_META, bytes=size), CARD_SUMMARY) for size in (1, 2))
        path, _, _ = cards.write(self.library, UUID, old)
        self.assertEqual(path.stat().st_mode & 0o777, 0o640)
        events, real_replace, real_fsync = [], os.replace, os.fsync

        def replace(src, dst):
            events.append(("replace", Path(src).parent, Path(src).read_text(), Path(dst).read_text()))
            real_replace(src, dst)

        def fsync(fd):
            events.append(("fsync library" if os.path.samestat(os.fstat(fd), self.library.stat()) else "fsync",))
            real_fsync(fd)

        with mock.patch("os.replace", replace), mock.patch("os.fsync", fsync):
            cards.write(self.library, UUID, new)
        self.assertEqual(events, [("fsync",), ("replace", self.library, new, old), ("fsync library",)])
        self.assertEqual((path.read_text(), self.files()), (new, [path.name]))
        with mock.patch("os.replace", side_effect=OSError("disk full")), self.assertRaises(OSError):
            cards.write(self.library, UUID, old)
        self.assertEqual((path.read_text(), self.files()), (new, [path.name]))
        absent = self.library.parent / "absent"
        with self.assertRaises(FileNotFoundError):
            cards.write(absent, UUID, old)
        self.assertFalse(absent.exists())


def call(*argv, env=None):
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        rc = cli.main(list(argv), env)
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

    def test_cli_flags_parse(self):
        args = cli.parser().parse_args(["run", "--session", UUID.upper(), "--dry-run", "--limit", "1", "--keep"])
        self.assertEqual((args.command, args.session, args.dry_run, args.limit, args.keep),
                         ("run", UUID, True, 1, True))
        args = cli.parser().parse_args(["run"])
        self.assertEqual((args.session, args.dry_run, args.limit, args.keep), (None, False, None, False))
        self.assertEqual((cli.parser().parse_args(["status", "--json"]).json, cli.parser().parse_args(["status"]).json),
                         (True, False))
        self.assertIs(cli.parser().parse_args(["review"]).handler, cli.review)

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


FIXTURE_SUMMARY = summary_of(
    why=[item("The operator asked for a sorted catalogue.", [2], "Sort the widget catalogue by name")],
    outcome=[item("The shelves were repainted.", [5], "the shelves were repainted blue")],
)
MERGED = {**FIXTURE_SUMMARY, "what": "Sorted the widget catalogue and kept a backup."}
FIXTURE_RESPONSES = [FIXTURE_SUMMARY] * 3 + [MERGED]
SPOKEN_SUMMARY = summary_of(why=[item("The operator asked for a sorted list.", [1], "please sort the widget list")])
PER_CALL = summarize.price(summarize.STUB_USAGE, "claude-haiku-5-5")
# 0.015 USD a call: one call spends past a cap that a small session's projection fits under.
BIG_USAGE = {"input_tokens": 100_000, "output_tokens": 10_000, "cache_creation_input_tokens": 0,
             "cache_read_input_tokens": 0}
FOURTH_UUID = "5a6b7c8d-9e0f-4a1b-8c2d-3e4f5a6b7c8d"
STATUS_FIELDS = {"last_run", "last_result", "eligible", "held", "review", "last_run_usd", "run_sessions", "root_ok",
                 "owner_ok"}


def journal(scanned=1, eligible=1, done=0, held=0, review=0, windows=0, archived=0, cards=0, usd="0.00"):
    return (f"session-archive: scanned={scanned} eligible={eligible} done={done} held={held} review={review} "
            f"windows={windows} usd={usd} archived={archived} cards={cards}")


def names(folder):
    return sorted(path.name for path in folder.iterdir())


def failed(error):
    """A completion that gave no summary, as ApiTransport returns it for error."""
    return summarize.Completion(None, dict.fromkeys(API_USAGE, 0), 0.0, "claude-haiku-5-5", None, error)


def tree(top):
    """Every file under top with the SHA-256 and mtime of its bytes."""
    return {str(p.relative_to(top)): (sha256(p), p.stat().st_mtime_ns) for p in sorted(top.rglob("*")) if p.is_file()}


class Lane(Scratch):
    """A scratch box with an archive root and a library, as machine box-a."""

    def setUp(self):
        super().setUp()
        self.root, self.library = self.tmp / "archive", self.tmp / "library"
        self.root.mkdir()
        self.library.mkdir()
        self.env.update({"SESSION_ARCHIVE_ROOT": str(self.root), "SESSION_ARCHIVE_MACHINE_ID": "box-a"})
        self.cfg = config.load(self.env)
        self.work = self.cfg.state_dir / "work"

    def fixture(self, uuid=UUID, slug=SLUG):
        path = self.tmp / "state/claude/projects" / slug / f"{uuid}.jsonl"
        path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(FIXTURE, path)
        os.utime(path, (OLD.timestamp(), OLD.timestamp()))
        return path

    def lane(self, responses, cfg=None, usage=summarize.STUB_USAGE, **options):
        stub = summarize.StubTransport(responses, usage)
        return pipeline.run(cfg or self.cfg, self.store, stub, NOW, **options), stub

    def card(self, uuid=UUID):
        return self.library / f"session-{uuid}.md"

    def copy_of(self, path, uuid=UUID, slug=SLUG):
        return self.root / slug / f"{uuid}.{sha256(path)[:8]}.jsonl.gz"

    def count(self, table):
        return self.store.db.execute(f"SELECT count(*) FROM {table}").fetchone()[0]

    def transcript_path(self, uuid=UUID, slug=SLUG):
        return self.tmp / "state/claude/projects" / slug / f"{uuid}.jsonl"

    def three_sessions(self):
        for uuid, hours in ((UUID, 0), (OTHER_UUID, 1), (THIRD_UUID, 2)):
            self.transcript(spoken(OLD + timedelta(hours=hours)), uuid=uuid)


class PipelineTest(Lane):
    def test_run_writes_card_archive_and_state(self):
        path = self.fixture()
        source = tree(self.tmp / "state")
        done, stub = self.lane(FIXTURE_RESPONSES)
        self.assertEqual(pipeline.journal(done), journal(done=1, windows=3, archived=1, cards=1))
        self.assertEqual(done.result, "ok")
        self.assertAlmostEqual(done.usd, 4 * PER_CALL)
        for number, call_made in enumerate(stub.calls[:3], 1):
            self.assertTrue(call_made["user"].startswith(f"SESSION {UUID}\nWINDOW {number} of 3; "))
        self.assertTrue(stub.calls[3]["user"].startswith("PART 1 of 3\n"))
        archived = self.copy_of(path)
        self.assertEqual((names(self.root / SLUG), names(self.library)), ([archived.name], [self.card().name]))
        self.assertEqual(gzip.decompress(archived.read_bytes()), FIXTURE.read_bytes())
        card = self.card().read_text()
        self.assertIn("\n## What\n\nSorted the widget catalogue and kept a backup.\n", card)
        self.assertIn('\n- The operator asked for a sorted catalogue. @L2\n  > "Sort the widget catalogue by name"\n',
                      card)
        self.assertIn('\n- The shelves were repainted. (unverified) @L5\n', card)
        self.assertEqual(card.split("\n## Pointer\n\n")[1].splitlines(), [
            f"Archive: {archived}", f"SHA-256: {sha256(path)}", f"Bytes: {path.stat().st_size}",
            f"Fetch: zcat '{archived}'", f"Local (until cleanup): {path}", f"Project: {SLUG}", "Area: lab",
            "Recipe: session-archive-v1", "Model: claude-haiku-5-5/low", "Extracted: 2026-01-20"])
        row = self.store.session(UUID)
        self.assertEqual((row["status"], row["reason"], row["sha256"], row["area"], row["archive_path"], row["holds"]),
                         ("done", None, sha256(path), "lab", str(archived), 0))
        self.assertEqual((row["card_hash"], row["size"]), (cards.content_hash(card), path.stat().st_size))
        last = self.store.last_run()
        self.assertEqual((last["result"], json.loads(last["counts"])["done"], self.count("ledger")), ("ok", 1, 4))
        self.assertEqual(names(self.work), [])
        self.assertEqual(tree(self.tmp / "state"), source)

    def test_run_is_idempotent_second_run_skips(self):
        self.fixture()
        self.lane(FIXTURE_RESPONSES)
        written, row = (tree(self.root), tree(self.library)), dict(self.store.session(UUID))
        done, stub = self.lane([])
        self.assertEqual(pipeline.journal(done), journal(eligible=0))
        self.assertEqual((stub.calls, done.result, done.usd), ([], "ok", 0.0))
        self.assertEqual(((tree(self.root), tree(self.library)), dict(self.store.session(UUID))), (written, row))
        self.assertEqual((self.count("runs"), self.count("ledger")), (2, 4))

    def test_run_rewrites_card_and_adds_archive_copy_when_sha_changes(self):
        path = self.fixture()
        self.lane(FIXTURE_RESPONSES, keep=True)
        first, work = self.copy_of(path), self.work / UUID
        self.assertEqual(names(work), ["rendered.txt", "summary.json", "w1.json", "w1.txt", "w2.json", "w2.txt",
                                       "w3.json", "w3.txt"])
        self.assertEqual(json.loads((work / "summary.json").read_text()), MERGED)
        self.transcript(spoken(OLD + timedelta(hours=1)), append=True)
        grown = {**MERGED, "what": "Sorted the catalogue, then the widget list."}
        done, _ = self.lane([FIXTURE_SUMMARY] * 3 + [grown])
        self.assertEqual(pipeline.journal(done), journal(done=1, windows=3, archived=1, cards=1))
        second = self.copy_of(path)
        self.assertEqual(names(self.root / SLUG), sorted([first.name, second.name]))
        self.assertEqual(gzip.decompress(first.read_bytes()), FIXTURE.read_bytes())
        self.assertEqual(gzip.decompress(second.read_bytes()), path.read_bytes())
        card = self.card().read_text()
        self.assertIn("\n## What\n\nSorted the catalogue, then the widget list.\n", card)
        self.assertIn(f"\nArchive: {second}\nSHA-256: {sha256(path)}\nBytes: {path.stat().st_size}\n", card)
        row = self.store.session(UUID)
        self.assertEqual((row["sha256"], row["archive_path"], row["card_hash"]),
                         (sha256(path), str(second), cards.content_hash(card)))
        self.assertFalse(work.exists())

    def test_run_stops_at_cap_after_finishing_session(self):
        self.three_sessions()
        capped = config.load({**self.env, "SESSION_ARCHIVE_RUN_CAP_USD": "0.01"})
        done, stub = self.lane([SPOKEN_SUMMARY] * 3, cfg=capped, usage=BIG_USAGE)
        self.assertEqual(pipeline.journal(done), journal(scanned=3, eligible=3, done=1, windows=1, archived=1, cards=1,
                                                         usd=f"{summarize.price(BIG_USAGE, 'claude-haiku-5-5'):.2f}"))
        self.assertEqual((done.result, len(stub.calls), self.store.last_run()["result"]), ("capped", 1, "capped"))
        self.assertGreaterEqual(done.usd, 0.01)
        self.assertEqual((names(self.library), self.store.session(UUID)["status"]), ([self.card().name], "done"))
        self.assertEqual((self.store.session(OTHER_UUID), self.store.session(THIRD_UUID)), (None, None))
        done, stub = self.lane([], cfg=config.load({**self.env, "SESSION_ARCHIVE_RUN_CAP_USD": "0"}))
        self.assertEqual((done.counts["eligible"], done.counts["done"], stub.calls, done.result), (2, 0, [], "capped"))

    def test_run_takes_at_most_limit_and_run_sessions(self):
        self.three_sessions()
        done, _ = self.lane([SPOKEN_SUMMARY] * 3, limit=1)
        self.assertEqual((done.counts["eligible"], done.counts["done"], done.result), (3, 1, "ok"))
        done, _ = self.lane([SPOKEN_SUMMARY] * 3, cfg=config.load({**self.env, "SESSION_ARCHIVE_RUN_SESSIONS": "1"}),
                            limit=2)
        self.assertEqual((done.counts["eligible"], done.counts["done"], done.result), (2, 1, "ok"))
        self.assertEqual([self.store.session(uuid)["status"] for uuid in (UUID, OTHER_UUID)], ["done", "done"])
        self.assertIsNone(self.store.session(THIRD_UUID))

    def test_run_holds_session_on_model_error(self):
        self.transcript(spoken())
        self.transcript(spoken(OLD + timedelta(hours=1)), uuid=OTHER_UUID)
        # A request only this session makes fail (http 400) holds it, and the run goes on.
        done, _ = self.lane([failed("http 400"), SPOKEN_SUMMARY])
        self.assertEqual(pipeline.journal(done),
                         journal(scanned=2, eligible=2, done=1, held=1, windows=2, archived=1, cards=1))
        row = self.store.session(UUID)
        self.assertEqual((row["status"], row["reason"], row["holds"], row["card_hash"], row["archive_path"]),
                         ("held", "model_error", 1, None, None))
        self.assertEqual(names(self.library), [self.card(OTHER_UUID).name])
        self.assertEqual([name[:36] for name in names(self.root / SLUG)], [OTHER_UUID])
        self.assertEqual((names(self.work), names(self.work / UUID)), ([UUID], ["rendered.txt", "w1.txt"]))
        # A held session is retried until its third hold; any other failure of the model side holds it too.
        for responses, reason, holds in ((["not json {"], "unparsable", 2), ([], "model_error", 3)):
            done, _ = self.lane(responses)
            row = self.store.session(UUID)
            self.assertEqual((done.counts["held"], row["reason"], row["holds"]), (1, reason, holds))
        done, stub = self.lane([])
        self.assertEqual((done.counts["eligible"], stub.calls), (0, []))
        done, _ = self.lane([SPOKEN_SUMMARY], session=UUID)
        self.assertEqual(pipeline.journal(done), journal(scanned=2, done=1, windows=1, archived=1, cards=1))
        self.assertEqual((self.store.session(UUID)["status"], self.store.session(UUID)["holds"]), ("done", 0))
        self.assertTrue(self.card().exists())
        self.assertFalse((self.work / UUID).exists())

    def test_run_holds_session_when_archive_copy_fails(self):
        path = self.transcript(spoken())
        taken = self.copy_of(path)
        taken.parent.mkdir()
        taken.write_bytes(gzip.compress(b"another transcript\n"))
        done, stub = self.lane([SPOKEN_SUMMARY])
        self.assertEqual(pipeline.journal(done), journal(held=1, windows=1))
        self.assertEqual((len(stub.calls), self.store.session(UUID)["reason"]), (1, "archive_error"))
        self.assertAlmostEqual(done.usd, PER_CALL)
        self.assertEqual((gzip.decompress(taken.read_bytes()), names(self.library)), (b"another transcript\n", []))
        self.assertEqual(names(self.work / UUID), ["rendered.txt", "summary.json", "w1.json", "w1.txt"])
        taken.unlink()
        shutil.rmtree(self.library)
        for holds, archived in ((2, 1), (3, 0)):
            done, _ = self.lane([SPOKEN_SUMMARY])
            self.assertEqual(pipeline.journal(done), journal(held=1, windows=1, archived=archived))
            row = self.store.session(UUID)
            self.assertEqual((row["status"], row["reason"], row["holds"], row["archive_path"]),
                             ("held", "library_missing", holds, None))
        self.assertEqual((names(self.root / SLUG), self.library.exists()), ([taken.name], False))

    def test_run_routes_unclear_area_to_review(self):
        self.transcript(spoken())
        self.cfg.state_dir.joinpath("review.md").write_text(f"- 2026-01-02 {UUID} unclear_area\n")
        done, _ = self.lane([{**SPOKEN_SUMMARY, "area": "unclear"}])
        self.assertEqual(pipeline.journal(done), journal(review=1, windows=1))
        row = self.store.session(UUID)
        self.assertEqual((row["status"], row["reason"], row["area"], row["card_hash"], row["archive_path"]),
                         ("review", "unclear_area", None, None, None))
        entry = f"- 2026-01-20 {UUID} unclear_area\n"
        self.assertEqual((self.cfg.state_dir / "review.md").read_text(), f"- 2026-01-02 {UUID} unclear_area\n{entry}")
        self.assertEqual((names(self.root), names(self.library), names(self.work)), ([], [], []))
        self.assertEqual(self.lane([])[0].counts["eligible"], 0)
        self.assertEqual(call("review", env=self.env), (0, entry, ""))
        # One line per waiting session, the last review.md has for it; a row review.md lacks still shows.
        self.record(self.transcript(spoken(), uuid=OTHER_UUID), "review", reason="unclear_area")
        since = self.store.session(OTHER_UUID)["updated"][:10]
        self.assertEqual(call("review", env=self.env), (0, f"{entry}- {since} {OTHER_UUID} unclear_area\n", ""))
        done, _ = self.lane([SPOKEN_SUMMARY], session=UUID)
        self.assertEqual((done.counts["done"], self.store.session(UUID)["status"]), (1, "done"))
        self.assertEqual(call("review", env=self.env), (0, f"- {since} {OTHER_UUID} unclear_area\n", ""))
        self.store.record_session(OTHER_UUID, SLUG, "a" * 64, "done", size=1, mtime=1.0, last_entry=None)
        self.assertEqual(call("review", env=self.env), (0, "no session waits for review\n", ""))

    def test_dry_run_makes_no_model_calls(self):
        self.fixture()
        self.transcript(spoken(OLD + timedelta(days=1)), uuid=OTHER_UUID)
        before = (tree(self.tmp / "state"), names(self.root), names(self.library))
        done, stub = self.lane([], dry_run=True)
        self.assertEqual((pipeline.journal(done), stub.calls), (journal(scanned=2, eligible=2, windows=4), []))
        done = pipeline.run(self.cfg, self.store, None, NOW, dry_run=True, limit=1)
        self.assertEqual(pipeline.journal(done), journal(scanned=2, eligible=2, windows=3))
        self.assertEqual(call("run", "--dry-run", env=self.env),
                         (0, journal(scanned=2, eligible=2, windows=4) + "\n", ""))
        self.assertEqual(call("run", "--dry-run", "--session", OTHER_UUID, env=self.env),
                         (0, journal(scanned=2, windows=1) + "\n", ""))
        self.assertEqual((tree(self.tmp / "state"), names(self.root), names(self.library)), before)
        self.assertEqual([self.count(table) for table in ("sessions", "runs", "ledger")], [0, 0, 0])
        self.assertEqual(names(self.cfg.state_dir), ["state.sqlite3"])
        fresh = {**self.env, "XDG_STATE_HOME": str(self.tmp / "fresh")}
        self.assertEqual(call("run", "--dry-run", env=fresh), (0, journal(scanned=2, eligible=2, windows=4) + "\n", ""))
        self.assertFalse((self.tmp / "fresh").exists())
        rc, out, err = call("status", "--json", env=self.env)
        self.assertEqual((rc, err, [json.loads(out)[name] for name in ("last_run", "eligible")]), (0, "", [None, None]))
        rc, out, err = call("run", env={**self.env, "SESSION_ARCHIVE_ROOT": ""})
        self.assertEqual((rc, out), (1, ""))
        self.assertIn("SESSION_ARCHIVE_ROOT is not set", err)

    def test_run_writes_work_files_as_utf8_under_c_locale(self):
        """The timer's locale can be C (ASCII): work files and the card are UTF-8 all the same."""
        self.transcript([said("user", "sortiere die Größen ✓"),
                         said("assistant", [{"type": "text", "text": "Erledigt — nach Größe."}])])
        summary = summary_of(what="Sortierte die Größen.", why=[item("Nach Größe.", [1], "sortiere die Größen")])
        script = ("import json, os, sys\nfrom datetime import datetime\n"
                  "from session_archive import config, pipeline, store, summarize\n"
                  "cfg = config.load(os.environ)\n"
                  "stub = summarize.StubTransport([json.loads(sys.argv[1])])\n"
                  "done = pipeline.run(cfg, store.Store(cfg.state_dir / 'state.sqlite3'), stub,\n"
                  "                    datetime.fromisoformat(sys.argv[2]), keep=True)\n"
                  "print(pipeline.journal(done))\n")
        env = {**self.env, "PATH": os.environ.get("PATH", ""), "PYTHONPATH": str(LIB), "PYTHONDONTWRITEBYTECODE": "1",
               "LC_ALL": "C", "PYTHONUTF8": "0"}
        proc = subprocess.run([sys.executable, "-c", script, json.dumps(summary), NOW.isoformat()], env=env,
                              capture_output=True, text=True, timeout=60, check=False)
        self.assertEqual((proc.returncode, proc.stdout, proc.stderr),
                         (0, journal(done=1, windows=1, archived=1, cards=1) + "\n", ""))
        self.assertIn("OPERATOR: sortiere die Größen ✓\n", (self.work / UUID / "rendered.txt").read_text("utf-8"))
        self.assertEqual(json.loads((self.work / UUID / "summary.json").read_text("utf-8")), summary)
        self.assertIn("\n## What\n\nSortierte die Größen.\n", self.card().read_text("utf-8"))
        # A work file that cannot be written holds its session, before any model call.
        shutil.rmtree(self.work)
        self.work.write_text("not a folder\n")
        self.transcript(spoken(), uuid=OTHER_UUID)
        done, stub = self.lane([SPOKEN_SUMMARY])
        self.assertEqual((done.counts["held"], stub.calls, self.store.session(OTHER_UUID)["reason"]),
                         (1, [], "work_error"))

    def test_run_holds_too_large_session_without_calls(self):
        self.fixture()
        self.transcript(spoken(OLD + timedelta(days=1)), uuid=OTHER_UUID)
        # The fixture projects 3 windows x (60,137 B / 3.5 at 0.10 + 4,000 at 0.50 USD per million) and one merge
        # (40,000 at 0.10 + 6,000 at 0.50): 0.0182 USD.
        done, stub = self.lane([SPOKEN_SUMMARY], cfg=config.load({**self.env, "SESSION_ARCHIVE_RUN_CAP_USD": "0.01"}))
        self.assertEqual(pipeline.journal(done),
                         journal(scanned=2, eligible=2, done=1, held=1, windows=4, archived=1, cards=1))
        row = self.store.session(UUID)
        self.assertEqual((row["status"], row["reason"], len(stub.calls)), ("held", "too_large", 1))
        self.assertEqual((names(self.work), self.store.session(OTHER_UUID)["status"]), ([], "done"))
        done, stub = self.lane(FIXTURE_RESPONSES, session=UUID)
        self.assertEqual((done.counts["done"], len(stub.calls)), (1, 4))
        # One that fits the cap but not what the run has left waits for the next run, and is not held.
        self.transcript(spoken(OLD - timedelta(days=1)), uuid=THIRD_UUID)
        self.fixture(uuid=FOURTH_UUID)
        done, stub = self.lane([SPOKEN_SUMMARY], cfg=config.load({**self.env, "SESSION_ARCHIVE_RUN_CAP_USD": "0.02"}),
                               usage=BIG_USAGE)
        self.assertEqual((done.result, done.counts["done"], len(stub.calls), self.store.session(FOURTH_UUID)),
                         ("capped", 1, 1, None))

    def test_run_finishes_session_in_flight_when_cap_trips_mid_session(self):
        half = "widget shelf " * 2800
        self.transcript([said("user", f"first half: {half}"), said("user", f"second half: {half}")])
        self.transcript(spoken(OLD + timedelta(days=1)), uuid=OTHER_UUID)
        cfg = config.load({**self.env, "SESSION_ARCHIVE_RUN_CAP_USD": "0.014"})
        done, stub = self.lane([SPOKEN_SUMMARY] * 4, cfg=cfg, usage=BIG_USAGE)
        self.assertEqual((done.result, len(stub.calls), done.counts["done"], done.counts["windows"]),
                         ("capped", 3, 1, 2))
        self.assertTrue(stub.calls[2]["user"].startswith("PART 1 of 2\n"))
        self.assertAlmostEqual(done.usd, 3 * summarize.price(BIG_USAGE, "claude-haiku-5-5"))
        self.assertEqual((names(self.library), self.store.session(OTHER_UUID)), ([self.card().name], None))

    def test_run_holds_empty_answer(self):
        self.transcript(spoken())
        done, _ = self.lane([summary_of(what="  ")])
        self.assertEqual(pipeline.journal(done), journal(held=1, windows=1))
        self.assertEqual((self.store.session(UUID)["reason"], names(self.root), names(self.library)),
                         ("unparsable", [], []))

    def test_run_holds_session_when_a_step_raises(self):
        self.three_sessions()
        real_render, real_check = render.render, cite.check

        def rendering(path, *args, **kwargs):
            if path.stem == UUID:
                raise ValueError("a renderer bug")
            return real_render(path, *args, **kwargs)

        def checking(summary, rendered):
            if rendered.uuid == OTHER_UUID:
                raise RecursionError("a citation check bug")
            return real_check(summary, rendered)

        with mock.patch.object(render, "render", rendering), mock.patch.object(cite, "check", checking):
            done, stub = self.lane([SPOKEN_SUMMARY] * 2)
        self.assertEqual(pipeline.journal(done),
                         journal(scanned=3, eligible=3, done=1, held=2, windows=2, archived=1, cards=1))
        self.assertEqual([self.store.session(uuid)["reason"] for uuid in (UUID, OTHER_UUID)], ["render_error"] * 2)
        self.assertEqual((len(stub.calls), self.store.session(THIRD_UUID)["status"]), (2, "done"))

    def test_archive_copy_is_idempotent_and_never_overwrites(self):
        path = self.transcript(spoken())
        sha = sha256(path)
        copied, created = archive.copy(self.root, SLUG, UUID, path, sha)
        self.assertEqual((copied, created), (self.root / SLUG / f"{UUID}.{sha[:8]}.jsonl.gz", True))
        self.assertEqual(gzip.decompress(copied.read_bytes()), path.read_bytes())
        stamp = copied.stat().st_mtime_ns
        self.assertEqual((archive.copy(self.root, SLUG, UUID, path, sha), copied.stat().st_mtime_ns),
                         ((copied, False), stamp))
        copied.write_bytes(gzip.compress(b"other bytes\n"))
        for root, uuid, digest in ((self.root, UUID, sha), (self.root, OTHER_UUID, "0" * 64), (None, UUID, sha),
                                   (self.tmp / "absent", UUID, sha)):
            with self.subTest(root=root, uuid=uuid), self.assertRaises(archive.ArchiveError) as caught:
                archive.copy(root, SLUG, uuid, path, digest)
            self.assertNotIn(str(self.tmp), str(caught.exception))
        self.assertEqual((gzip.decompress(copied.read_bytes()), names(self.root / SLUG)),
                         (b"other bytes\n", [copied.name]))
        self.assertFalse((self.tmp / "absent").exists())


class CliRunTest(Lane):
    def setUp(self):
        super().setUp()
        (self.tmp / "state/claude/projects").mkdir(parents=True, exist_ok=True)
        (self.tmp / "secrets.env").write_text(f"{LANE_KEY}=lane-test-key\n")
        self.env["FLAKELAB_SECRETS_ENV"] = str(self.tmp / "secrets.env")
        network = mock.patch("urllib.request.urlopen", side_effect=AssertionError("no network in tests"))
        network.start()
        self.addCleanup(network.stop)

    def test_run_refuses_root_owned_by_other_machine(self):
        keyless = {**self.env, "FLAKELAB_SECRETS_ENV": str(self.tmp / "absent.env")}
        self.assertEqual(call("run", env=keyless), (1, "", f"session-archive: {LANE_KEY} is not set in the flakelab "
                                                            "secrets file\n"))
        self.assertEqual((names(self.root), names(self.library)), ([], []))
        self.assertEqual(call("run", env=self.env), (0, journal(scanned=0, eligible=0) + "\n", ""))
        for folder in (self.root, self.library):
            self.assertEqual((folder / ".owner").read_text(), "box-a\n")
        other = {**self.env, "SESSION_ARCHIVE_MACHINE_ID": "box-b"}
        for argv in (["run"], ["run", "--dry-run"]):
            rc, out, err = call(*argv, env=other)
            self.assertEqual((rc, out), (1, ""))
            self.assertIn("owned by another box", err)
            self.assertNotIn(str(self.tmp), err)
        self.assertEqual(((self.root / ".owner").read_text(), self.count("runs")), ("box-a\n", 1))
        (self.root / ".owner").unlink()
        (self.library / ".owner").write_text("box-b\n")
        self.assertEqual(call("run", env=self.env)[0], 1)
        self.assertEqual((names(self.root), self.count("runs")), ([], 1))

    def test_run_stops_before_loop_when_root_unreachable(self):
        self.transcript(spoken())
        absent = {**self.env, "SESSION_ARCHIVE_ROOT": str(self.tmp / "absent")}
        done, stub = self.lane([SPOKEN_SUMMARY], cfg=config.load(absent))
        self.assertEqual((pipeline.journal(done), done.result, stub.calls), (journal(), "root_unreachable", []))
        self.assertEqual((self.store.session(UUID), self.count("ledger"), self.store.last_run()["result"]),
                         (None, 0, "root_unreachable"))
        self.assertEqual(call("run", env=absent), (1, journal() + "\n", "session-archive: the archive root is "
                                                                       "unreachable: the run took no session\n"))
        self.assertEqual((self.store.session(UUID), self.count("runs"), (self.tmp / "absent").exists()),
                         (None, 2, False))

    def test_run_stops_queue_on_transport_failure(self):
        self.transcript(spoken())
        self.transcript(spoken(OLD + timedelta(hours=1)), uuid=OTHER_UUID)
        # The outage is the transport's: no session is held, the one in flight is left as it was, work/ and all.
        # The second stop is another session's (--session), so neither is a repeat.
        for error, options, journaled in (("http 401", {}, journal(scanned=2, eligible=2, windows=1)),
                                          ("network TimeoutError", {"session": OTHER_UUID},
                                           journal(scanned=2, windows=1))):
            done, stub = self.lane([failed(error), SPOKEN_SUMMARY], **options)
            self.assertEqual((pipeline.journal(done), done.result, len(stub.calls)),
                             (journaled, "model_unavailable", 1))
            self.assertEqual((self.store.session(UUID), self.store.session(OTHER_UUID), self.store.held()),
                             (None, None, []))
            self.assertEqual(names(self.work), [])
        with mock.patch("urllib.request.urlopen", side_effect=http_error(403)):
            self.assertEqual(call("run", env=self.env), (1, journal(scanned=2, eligible=2, windows=1) + "\n",
                                                         "session-archive: the model API is unavailable (http 403): "
                                                         "the run stopped, holding no session\n"))
        self.assertEqual((self.store.session(UUID), self.store.session(OTHER_UUID), self.store.last_run()["result"]),
                         (None, None, "model_unavailable"))
        done, _ = self.lane([SPOKEN_SUMMARY] * 2)
        self.assertEqual((done.result, done.counts["done"], self.store.session(UUID)["holds"]), ("ok", 2, 0))

    def test_run_holds_session_that_stopped_two_runs_in_a_row(self):
        self.three_sessions()

        def stop(**options):
            done, _ = self.lane([failed("http 500")], **options)
            self.assertEqual(done.result, "model_unavailable")
            return self.store.session(UUID)

        self.assertIsNone(stop())
        self.assertIsNone(stop(session=OTHER_UUID))  # another session stopped in between: the mark moves to it
        self.assertIsNone(stop())
        # The same content stops a second run in a row: that is the session's failure, held, and the queue advances.
        done, stub = self.lane([failed("http 500"), SPOKEN_SUMMARY, SPOKEN_SUMMARY])
        self.assertEqual((pipeline.journal(done), done.result, len(stub.calls)),
                         (journal(scanned=3, eligible=3, done=2, held=1, windows=3, archived=2, cards=2), "ok", 3))
        row = self.store.session(UUID)
        self.assertEqual((row["status"], row["reason"], row["holds"]), ("held", "model_error", 1))
        self.assertEqual(names(self.work / UUID), ["rendered.txt", "w1.txt"])
        # A run that went through in between resets the mark, and so does new content.
        self.assertEqual(stop()["holds"], 1)
        self.transcript(spoken(OLD + timedelta(minutes=30)), append=True)
        self.assertEqual(stop()["holds"], 1)
        done, _ = self.lane([failed("http 500")])
        row = self.store.session(UUID)
        self.assertEqual((done.result, row["reason"], row["holds"], row["sha256"]),
                         ("ok", "model_error", 1, sha256(self.transcript_path())))

    def test_status_creates_nothing(self):
        fresh = str(self.tmp / "fresh")
        self.assertEqual(self.status(XDG_STATE_HOME=fresh), {
            "last_run": None, "last_result": None, "eligible": None, "held": 0, "review": 0, "last_run_usd": 0.0,
            "run_sessions": 20, "root_ok": True, "owner_ok": None})
        self.assertIn("last run: never\n", self.status(human=True, XDG_STATE_HOME=fresh))
        self.assertEqual(call("review", env={**self.env, "XDG_STATE_HOME": fresh}),
                         (0, "no session waits for review\n", ""))
        self.assertEqual((Path(fresh).exists(), names(self.root), names(self.library)), (False, [], []))
        self.transcript(spoken())
        self.lane([{**SPOKEN_SUMMARY, "area": "unclear"}])
        state = tree(self.cfg.state_dir)
        self.assertEqual((self.status()["review"], call("review", env=self.env)[0]), (1, 0))
        self.status(human=True)
        self.assertEqual((tree(self.cfg.state_dir), names(self.root), names(self.library)), (state, [], []))
        self.assertNotIn("lock", names(self.cfg.state_dir))

    def test_run_refuses_empty_root_after_first_claim(self):
        self.assertEqual(call("run", env=self.env)[0], 0)
        claims = self.store.db.execute("SELECT path, machine_id FROM claims ORDER BY path").fetchall()
        self.assertEqual([tuple(row) for row in claims],
                         sorted([(str(self.root), "box-a"), (str(self.library), "box-a")]))
        # The share comes unmounted: its mount point is an empty folder, which is not claimed again.
        (self.root / ".owner").unlink()
        self.transcript(spoken())
        self.assertEqual(call("run", env=self.env), (1, journal() + "\n", "session-archive: the archive root is "
                                                                         "unreachable: the run took no session\n"))
        self.assertEqual((names(self.root), self.store.session(UUID), self.store.last_run()["result"]),
                         ([], None, "root_unreachable"))
        self.assertIs(self.status()["root_ok"], False)
        (self.root / ".owner").write_text("box-a\n")
        (self.library / ".owner").unlink()
        self.assertEqual(call("run", env=self.env), (1, journal() + "\n", "session-archive: a library is "
                                                                         "unreachable: the run took no session\n"))
        self.assertEqual((names(self.library), self.store.session(UUID), self.store.last_run()["result"]),
                         ([], None, "library_unreachable"))
        self.assertIs(self.status()["root_ok"], True)
        (self.library / ".owner").write_text("box-a\n")
        done, _ = self.lane([SPOKEN_SUMMARY])
        self.assertEqual((done.result, self.store.session(UUID)["status"]), ("ok", "done"))

    def test_run_holds_in_flight_session_on_sigterm(self):
        self.transcript(spoken())
        self.transcript(spoken(OLD + timedelta(hours=1)), uuid=OTHER_UUID)
        called = self.tmp / "called"
        script = ("import sys, time, urllib.request\nfrom pathlib import Path\nfrom session_archive import cli\n"
                  "def blocked(request, timeout=None):\n    Path(sys.argv[1]).touch()\n    time.sleep(60)\n"
                  "urllib.request.urlopen = blocked\nsys.exit(cli.main(['run']))\n")
        env = {**self.env, "PATH": os.environ.get("PATH", ""), "PYTHONPATH": str(LIB), "PYTHONDONTWRITEBYTECODE": "1"}
        child = subprocess.Popen([sys.executable, "-c", script, str(called)], env=env, stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE, text=True)
        try:
            deadline = time.monotonic() + 30
            while not called.exists() and child.poll() is None and time.monotonic() < deadline:
                time.sleep(0.05)
            child.send_signal(signal.SIGTERM)
            out, err = child.communicate(timeout=30)
        finally:
            child.kill()
        self.assertEqual((child.returncode, out, err), (143, "", ""))
        row = self.store.session(UUID)
        self.assertEqual((row["status"], row["reason"], row["holds"]), ("held", "timeout", 1))
        self.assertEqual(names(self.work / UUID), ["rendered.txt", "w1.txt"])
        self.assertEqual((self.store.session(OTHER_UUID), self.store.last_run()["result"]), (None, "error"))

        class Interrupted:
            def complete(self, *args, **kwargs):
                raise KeyboardInterrupt

        with self.assertRaises(KeyboardInterrupt):
            pipeline.run(self.cfg, self.store, Interrupted(), NOW)
        self.assertEqual((self.store.session(UUID)["reason"], self.store.session(UUID)["holds"]), ("timeout", 2))

    def test_lock_second_instance_exits_zero(self):
        self.transcript(spoken())
        with open(self.cfg.state_dir / "lock", "a") as held:
            fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertEqual(call("run", env=self.env), (0, "already running\n", ""))
            # A dry run writes nothing, so it takes no lock and counts beside a run.
            self.assertEqual(call("run", "--dry-run", env=self.env), (0, journal(windows=1) + "\n", ""))
        self.assertEqual((self.count("runs"), self.count("sessions"), names(self.root)), (0, 0, []))

    def status(self, human=False, **changes):
        """status --json (or its lines) without a scan: eligible is the last run's count, the state root unread."""
        with mock.patch.object(sources, "scan", side_effect=AssertionError("status scanned the state root")):
            rc, out, err = call("status", *([] if human else ["--json"]), env={**self.env, **changes})
        self.assertEqual((rc, err), (0, ""))
        if human:
            return out
        report = json.loads(out)
        self.assertEqual(set(report), STATUS_FIELDS)
        return report

    def test_status_json_fields(self):
        self.assertEqual(self.status(), {"last_run": None, "last_result": None, "eligible": None, "held": 0,
                                         "review": 0, "last_run_usd": 0.0, "run_sessions": 20, "root_ok": True,
                                         "owner_ok": None})
        self.assertEqual((self.status(SESSION_ARCHIVE_ROOT="")["root_ok"],
                          self.status(SESSION_ARCHIVE_ROOT=str(self.tmp / "absent"))["root_ok"]), (None, False))
        self.fixture()
        self.transcript(spoken(OLD + timedelta(days=1)), uuid=OTHER_UUID)
        self.transcript(spoken(OLD + timedelta(days=2)), uuid=THIRD_UUID)
        self.assertIsNone(self.status()["eligible"])
        self.assertIn("\neligible at the last full run: not counted yet (20 per run)\n", self.status(human=True))
        self.lane(FIXTURE_RESPONSES + [{**SPOKEN_SUMMARY, "area": "unclear"}, failed("http 400")])
        archive.check_owner(self.root, "box-a")
        report = self.status(SESSION_ARCHIVE_RUN_SESSIONS="7")
        self.assertEqual(datetime.fromisoformat(report["last_run"]).tzinfo, UTC)
        self.assertAlmostEqual(report.pop("last_run_usd"), 5 * PER_CALL)
        self.assertEqual({**report, "last_run": None}, {
            "last_run": None, "last_result": "ok", "eligible": 3, "held": 1, "review": 1, "run_sessions": 7,
            "root_ok": True, "owner_ok": True})
        (self.library / ".owner").write_text("box-b\n")
        self.assertIs(self.status()["owner_ok"], False)
        out = self.status(human=True)
        self.assertIn("\neligible at the last full run: 3 (20 per run)\n", out)
        self.assertIn(f"{THIRD_UUID} model_error", out)
        self.assertNotIn(str(self.tmp), out)
        self.assertEqual(self.status(FLAKELAB_STATE_ROOT="")["eligible"], 3)
        # A run in progress has no result yet; the backlog stays the last full run's.
        self.store.start_run()
        self.assertEqual([self.status()[name] for name in ("last_result", "eligible")], [None, 3])

    def test_status_keeps_backlog_after_session_run(self):
        self.three_sessions()
        done, _ = self.lane([SPOKEN_SUMMARY], session=UUID)
        self.assertEqual(pipeline.journal(done), journal(scanned=3, done=1, windows=1, archived=1, cards=1))
        self.assertIsNone(json.loads(self.store.last_run()["counts"])["eligible"])
        self.assertEqual([self.status()[name] for name in ("last_result", "eligible")], ["ok", None])
        done, _ = self.lane([SPOKEN_SUMMARY], limit=1)
        self.assertEqual((done.counts["eligible"], self.status()["eligible"]), (2, 2))
        done, _ = self.lane([SPOKEN_SUMMARY], session=THIRD_UUID)
        self.assertEqual(pipeline.journal(done), journal(scanned=3, done=1, windows=1, archived=1, cards=1))
        last = self.store.last_run()
        self.assertEqual((last["result"], json.loads(last["counts"])["eligible"], self.count("runs")), ("ok", None, 3))
        report = self.status()
        self.assertEqual((report["last_run"], report["last_result"], report["eligible"]), (last["started"], "ok", 2))


if __name__ == "__main__":
    unittest.main(verbosity=2)
