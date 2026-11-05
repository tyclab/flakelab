"""Offline suite for `flakelab session-archive`: the shim and lib/session_archive/, run by test-session-archive."""

import contextlib
from datetime import UTC, datetime, timedelta
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import tempfile
import unittest

from session_archive import cli, config, render, sources, store, windows
from session_archive import secrets as lane_secrets

SHIM = Path(__file__).resolve().parent.parent / "session-archive"
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
            self.assertRegex(str(caught.exception), r"^the state database has schema version (0|7); this lane reads version 1:")
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
