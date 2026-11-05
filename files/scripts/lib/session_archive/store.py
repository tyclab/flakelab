"""Box-local sqlite state: a row per session, per run, per model call (the ledger) and per folder this box claimed."""

from datetime import UTC, datetime
import json
from pathlib import Path
import sqlite3
from uuid import uuid4

STATUSES = ("done", "held", "review")
# A done session whose archive copy and state-root transcript retention removed; set only by mark_pruned.
PRUNED = "pruned"
# Version 4 is version 3's tables plus the pruned status, which a version 3 lane would read as a review: a run marks
# a version 3 database 4, and a read-only open takes it as it is.
SCHEMA_VERSION = 4
READABLE = (3, SCHEMA_VERSION)
SCHEMA = (
    """CREATE TABLE sessions (
  uuid TEXT PRIMARY KEY, slug TEXT NOT NULL, sha256 TEXT NOT NULL, size INTEGER NOT NULL, mtime REAL NOT NULL,
  last_entry TEXT, status TEXT NOT NULL, reason TEXT, area TEXT, card_hash TEXT, archive_path TEXT,
  holds INTEGER NOT NULL DEFAULT 0, updated TEXT NOT NULL)""",
    """CREATE TABLE runs (run_id TEXT PRIMARY KEY, started TEXT NOT NULL, finished TEXT, result TEXT, counts TEXT,
  stopped_uuid TEXT, stopped_sha TEXT)""",
    """CREATE TABLE ledger (
  run_id TEXT NOT NULL, uuid TEXT NOT NULL, model_id TEXT NOT NULL, usage TEXT NOT NULL, usd REAL NOT NULL,
  at TEXT NOT NULL)""",
    "CREATE INDEX ledger_run ON ledger (run_id)",
    "CREATE TABLE claims (path TEXT PRIMARY KEY, machine_id TEXT NOT NULL, claimed_at TEXT NOT NULL)",
    f"PRAGMA user_version = {SCHEMA_VERSION}",
)
# area, card_hash and archive_path describe the last card and archive copy, which stay: a hold keeps them.
# A new SHA is new input, so the count of holds starts again.
RECORD = """
INSERT INTO sessions (uuid, slug, sha256, size, mtime, last_entry, status, reason, area, card_hash, archive_path,
                      holds, updated)
VALUES (:uuid, :slug, :sha256, :size, :mtime, :last_entry, :status, :reason, :area, :card_hash, :archive_path,
        :holds, :updated)
ON CONFLICT (uuid) DO UPDATE SET
  slug = excluded.slug, sha256 = excluded.sha256, size = excluded.size, mtime = excluded.mtime,
  last_entry = excluded.last_entry, status = excluded.status, reason = excluded.reason,
  area = COALESCE(excluded.area, area), card_hash = COALESCE(excluded.card_hash, card_hash),
  archive_path = COALESCE(excluded.archive_path, archive_path),
  holds = CASE WHEN excluded.status = 'done' THEN 0
               WHEN excluded.sha256 = sha256 THEN holds + excluded.holds
               ELSE excluded.holds END,
  updated = excluded.updated
"""


class StoreError(RuntimeError):
    """The state database cannot be used; the message names no path."""


def now_iso():
    return datetime.now(UTC).isoformat(timespec="seconds").replace("+00:00", "Z")


class Store:
    def __init__(self, path, readonly=False):
        """readonly opens an existing database and never creates or writes anything (status, review)."""
        self.path = Path(path)
        if readonly:
            self.db = sqlite3.connect(f"{self.path.absolute().as_uri()}?mode=ro", uri=True)
        else:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            self.db = sqlite3.connect(self.path)
        self.db.row_factory = sqlite3.Row
        try:
            version = self.db.execute("PRAGMA user_version").fetchone()[0] if readonly else self.schema()
        except BaseException:
            self.db.close()
            raise
        if version not in (READABLE if readonly else (SCHEMA_VERSION,)):
            self.db.close()
            raise StoreError(f"the state database has schema version {version}; this lane reads version "
                             f"{SCHEMA_VERSION}: move the database aside to start a new one")

    def schema(self):
        """Create the tables in an empty database, mark a version 3 one 4; the version of any other. One write lock: a
        second opener waits."""
        with self.db:
            self.db.execute("BEGIN IMMEDIATE")
            version = self.db.execute("PRAGMA user_version").fetchone()[0]
            if version == 0 and self.db.execute("SELECT count(*) FROM sqlite_master").fetchone()[0] == 0:
                for statement in SCHEMA:
                    self.db.execute(statement)
                version = SCHEMA_VERSION
            elif version == 3:
                self.db.execute(f"PRAGMA user_version = {SCHEMA_VERSION}")
                version = SCHEMA_VERSION
        return version

    def close(self):
        self.db.close()

    def record_session(self, uuid, slug, sha256, status, reason=None, area=None, card_hash=None, archive_path=None,
                       *, size: int, mtime: float, last_entry: datetime | None):
        """size, mtime and last_entry are the scan's, taken before sha256 was computed (the Candidate's fields)."""
        if status not in STATUSES:
            raise ValueError(f"unknown session status: {status}")
        with self.db:
            self.db.execute(RECORD, {
                "uuid": uuid, "slug": slug, "sha256": sha256, "size": int(size), "mtime": float(mtime),
                "last_entry": last_entry.isoformat() if last_entry else None, "status": status, "reason": reason,
                "area": area, "card_hash": card_hash, "archive_path": archive_path, "holds": int(status == "held"),
                "updated": now_iso(),
            })

    def session(self, uuid):
        return self.db.execute("SELECT * FROM sessions WHERE uuid = ?", (uuid,)).fetchone()

    def mark_pruned(self, uuid, sha256, card_hash) -> bool:
        """The done session at sha256 as pruned, its archive path cleared and its retired card's hash kept; False when
        the row is not that any more."""
        with self.db:
            return self.db.execute(
                "UPDATE sessions SET status = ?, reason = NULL, archive_path = NULL, card_hash = ?, updated = ? "
                "WHERE uuid = ? AND sha256 = ? AND status = 'done'",
                (PRUNED, card_hash, now_iso(), uuid, sha256)).rowcount == 1

    def start_run(self) -> str:
        started = now_iso()
        run_id = f"{started.replace('-', '').replace(':', '')}-{uuid4().hex[:8]}"
        with self.db:
            self.db.execute("INSERT INTO runs (run_id, started) VALUES (?, ?)", (run_id, started))
        return run_id

    def ledger_add(self, run_id, uuid, model_id, usage: dict, usd: float):
        with self.db:
            self.db.execute("INSERT INTO ledger (run_id, uuid, model_id, usage, usd, at) VALUES (?, ?, ?, ?, ?, ?)",
                            (run_id, uuid, model_id, json.dumps(usage, sort_keys=True), float(usd), now_iso()))

    def run_usd(self, run_id) -> float:
        return float(self.db.execute("SELECT TOTAL(usd) FROM ledger WHERE run_id = ?", (run_id,)).fetchone()[0])

    def finish_run(self, run_id, result, counts: dict):
        with self.db:
            self.db.execute("UPDATE runs SET finished = ?, result = ?, counts = ? WHERE run_id = ?",
                            (now_iso(), result, json.dumps(counts, sort_keys=True), run_id))

    def mark_stopped(self, run_id, uuid, sha256):
        """The session (and content) a run stopped on with model_unavailable."""
        with self.db:
            self.db.execute("UPDATE runs SET stopped_uuid = ?, stopped_sha = ? WHERE run_id = ?",
                            (uuid, sha256, run_id))

    def stopped_before(self, run_id):
        """(uuid, sha256) the run before run_id stopped on, or None when that run did not stop on a session."""
        row = self.db.execute("SELECT stopped_uuid, stopped_sha FROM runs WHERE run_id != ? "
                              "ORDER BY started DESC, rowid DESC LIMIT 1", (run_id,)).fetchone()
        return (row["stopped_uuid"], row["stopped_sha"]) if row is not None and row["stopped_uuid"] else None

    def last_run(self):
        return self.db.execute("SELECT * FROM runs ORDER BY started DESC, rowid DESC LIMIT 1").fetchone()

    def last_count(self, name):
        """name's value in the most recent run's counts that hold one (not None); None when no run recorded it."""
        for (counts,) in self.db.execute("SELECT counts FROM runs WHERE counts IS NOT NULL "
                                         "ORDER BY started DESC, rowid DESC"):
            value = json.loads(counts).get(name)
            if value is not None:
                return value
        return None

    def claim(self, path, machine_id):
        """The first claim of a folder (archive root or library) by this box; later ones change nothing."""
        with self.db:
            self.db.execute("INSERT OR IGNORE INTO claims (path, machine_id, claimed_at) VALUES (?, ?, ?)",
                            (str(path), machine_id, now_iso()))

    def claimed(self, path) -> bool:
        return self.db.execute("SELECT 1 FROM claims WHERE path = ?", (str(path),)).fetchone() is not None

    def held(self):
        return self.by_status("held")

    def review(self):
        return self.by_status("review")

    def by_status(self, status):
        return self.db.execute("SELECT * FROM sessions WHERE status = ? ORDER BY updated, uuid", (status,)).fetchall()
