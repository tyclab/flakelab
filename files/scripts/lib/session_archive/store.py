"""Box-local sqlite state: a row per session, a row per run and a ledger row per model call."""

from datetime import UTC, datetime
import json
from pathlib import Path
import sqlite3
from uuid import uuid4

STATUSES = ("done", "held", "review")
SCHEMA = """
CREATE TABLE IF NOT EXISTS sessions (
  uuid TEXT PRIMARY KEY, slug TEXT NOT NULL, sha256 TEXT NOT NULL, size INTEGER NOT NULL, mtime REAL NOT NULL,
  status TEXT NOT NULL, reason TEXT, area TEXT, card_hash TEXT, archive_path TEXT, holds INTEGER NOT NULL DEFAULT 0,
  updated TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS runs (
  run_id TEXT PRIMARY KEY, started TEXT NOT NULL, finished TEXT, result TEXT, counts TEXT);
CREATE TABLE IF NOT EXISTS ledger (
  run_id TEXT NOT NULL, uuid TEXT NOT NULL, model_id TEXT NOT NULL, usage TEXT NOT NULL, usd REAL NOT NULL,
  at TEXT NOT NULL);
CREATE INDEX IF NOT EXISTS ledger_run ON ledger (run_id);
"""
# area, card_hash and archive_path describe the last card and archive copy, which stay: a hold keeps them.
# A new SHA is new input, so the count of holds starts again.
RECORD = """
INSERT INTO sessions (uuid, slug, sha256, size, mtime, status, reason, area, card_hash, archive_path, holds, updated)
VALUES (:uuid, :slug, :sha256, :size, :mtime, :status, :reason, :area, :card_hash, :archive_path, :holds, :updated)
ON CONFLICT (uuid) DO UPDATE SET
  slug = excluded.slug, sha256 = excluded.sha256, size = excluded.size, mtime = excluded.mtime,
  status = excluded.status, reason = excluded.reason,
  area = COALESCE(excluded.area, area), card_hash = COALESCE(excluded.card_hash, card_hash),
  archive_path = COALESCE(excluded.archive_path, archive_path),
  holds = CASE WHEN excluded.status = 'done' THEN 0
               WHEN excluded.sha256 = sha256 THEN holds + excluded.holds
               ELSE excluded.holds END,
  updated = excluded.updated
"""


def now_iso():
    return datetime.now(UTC).isoformat(timespec="seconds").replace("+00:00", "Z")


class Store:
    def __init__(self, path):
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.db = sqlite3.connect(self.path)
        self.db.row_factory = sqlite3.Row
        with self.db:
            self.db.executescript(SCHEMA)

    def close(self):
        self.db.close()

    def record_session(self, uuid, slug, sha256, status, reason=None, area=None, card_hash=None, archive_path=None,
                       *, size: int, mtime: float):
        """size and mtime are the stat taken before sha256 was computed (Candidate.size, Candidate.mtime)."""
        if status not in STATUSES:
            raise ValueError(f"unknown session status: {status}")
        with self.db:
            self.db.execute(RECORD, {
                "uuid": uuid, "slug": slug, "sha256": sha256, "size": int(size), "mtime": float(mtime),
                "status": status, "reason": reason, "area": area, "card_hash": card_hash,
                "archive_path": archive_path, "holds": int(status == "held"), "updated": now_iso(),
            })

    def session(self, uuid):
        return self.db.execute("SELECT * FROM sessions WHERE uuid = ?", (uuid,)).fetchone()

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

    def last_run(self):
        return self.db.execute("SELECT * FROM runs ORDER BY started DESC, rowid DESC LIMIT 1").fetchone()

    def held(self):
        return self.by_status("held")

    def review(self):
        return self.by_status("review")

    def by_status(self, status):
        return self.db.execute("SELECT * FROM sessions WHERE status = ? ORDER BY updated, uuid", (status,)).fetchall()
