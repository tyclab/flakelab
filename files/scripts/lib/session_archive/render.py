"""Render one Claude Code transcript as line-anchored, speaker-tagged, redacted text; reads the file, writes nothing.

Each record renders whole as `@L<line> <time> <SPEAKER>: <text>` (line: 1-based JSONL line, shared by the blocks of one
line). Speakers: OPERATOR (typed or queued prompt, slash command, shell input), ASSISTANT, CALL(<tool>), RESULT(<tool>),
HANDBACK (a subagent's or peer session's report) and SYSTEM (any other text that is not the operator's). A leading
bracketed note marks text whose attribution needs care: pasted, possibly relayed, an error, a peer, a summary.
"""

from dataclasses import dataclass, replace
from datetime import UTC, datetime
import json
from pathlib import Path
import re

MAX_RECORD = 60_000
CUT = " [...{} chars cut...]"
PASTED, RELAYED, ERROR = "[pasted] ", "[long; may relay another agent] ", "[error] "
PEER, SUMMARY = "[peer session; not the operator] ", "[compaction summary; generated, not evidence] "
SYSTEM_TAGS = ("<bash-stdout>", "<bash-stderr>", "<local-command-", "<system-reminder")
DATED = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T")
SURROGATE = re.compile("[\ud800-\udfff]")
# A token's start: not inside a word, or right after an escaped newline or tab of JSON-dumped text.
START = r"(?:(?<![A-Za-z0-9_])|(?<=\\[nrt]))"
KEY_NAME = (r"[\w.-]{0,64}?(?:pass(?:word|wd|phrase)|secret|token|psk|\w_session"
            r"|(?:api|access|private|secret|signing)[_-]?key)")
LINE_END = r"(?=\r?\n|\\r?\\n|$)"
# Pilot rules with an 8-character floor: a cut tool result once let a 21-character session token prefix through.
RULES = [(name, re.compile(pattern)) for name, pattern in (
    ("pem", r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?-----(?:[\s\S]*?-----END [A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?-----"
            rf"|(?:(?:\r?\n|\\r?\\n)+(?:[A-Za-z0-9+/=]+|[A-Za-z-]+:[^\n\\]*){LINE_END})*)"),
    ("anthropic", rf"{START}sk-ant-[A-Za-z0-9_-]{{8,}}"),
    ("gitlab", rf"{START}glpat-[A-Za-z0-9_-]{{8,}}"),
    ("github", rf"{START}(?:gh[pousr]_[A-Za-z0-9]{{8,}}|github_pat_[A-Za-z0-9_]{{8,}})"),
    ("slack", rf"{START}xox[abposr]-[A-Za-z0-9-]{{8,}}"),
    ("aws", rf"{START}AKIA[0-9A-Z]{{16}}"),
    ("jwt", rf"{START}eyJ[A-Za-z0-9_-]{{8,}}\.eyJ[A-Za-z0-9_-]{{8,}}\.[A-Za-z0-9_-]{{8,}}"),
    ("vault", rf"{START}hv[sbr]\.[A-Za-z0-9_-]{{8,}}"),
    ("bearer", r"(?i)(\bbearer\s+)(?!\[REDACTED)[A-Za-z0-9._~+/=-]{8,}"),
    ("assign", rf"(?i)(\b{KEY_NAME}\b\\*[\"']?\s*[:=]\s*\\*[\"']?)(?!\[REDACTED|\$)[^\s\"'<>]{{8,}}"),
)]


@dataclass(frozen=True)
class Record:
    line: int
    time: str
    speaker: str
    text: str

    @property
    def rendered(self):
        anchor = " ".join(part for part in (f"@L{self.line}", self.time, self.speaker) if part)
        return f"{anchor}: {self.text}"


@dataclass(frozen=True)
class Rendered:
    text: str
    records: list[Record]
    cuts: list[tuple[int, int]]
    skipped_lines: int
    bytes_in: int
    uuid: str
    redactions: dict[str, int]


def redact(text, counts=None):
    """Credential shapes masked as [REDACTED:<rule>], keeping a key name or `Bearer`; counts gains each rule's hits."""
    for name, rule in RULES:
        def mask(match, name=name, keep=rule.groups):
            if counts is not None:
                counts[name] = counts.get(name, 0) + 1
            return f"{match.group(1) if keep else ''}[REDACTED:{name}]"
        text = rule.sub(mask, text)
    return text


def when(stamp):
    if not isinstance(stamp, str) or not DATED.match(stamp):
        return ""
    try:
        moment = datetime.fromisoformat(stamp)
    except ValueError:
        return ""
    if moment.tzinfo is None:
        return moment.strftime("%Y-%m-%dT%H:%M:%S")
    return moment.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def flat(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for block in content:
            if not isinstance(block, dict):
                parts.append(str(block))
            elif block.get("type") == "text":
                parts.append(flat(block.get("text")))
            elif block.get("type") == "image":
                parts.append("[image]")
            else:
                parts.append(flat(block.get("content")))
        return "\n".join(parts)
    return "" if content is None else json.dumps(content, ensure_ascii=False)


def prompt(text, origin, record):
    """(speaker, note, text) of a user message or queued command."""
    kind = origin.get("kind") if isinstance(origin, dict) else None
    head = text.lstrip()
    if kind == "peer":
        return ("HANDBACK", "", text) if origin.get("handback") else ("SYSTEM", PEER, text)
    if kind == "task-notification" or head.startswith("<task-notification"):
        return "HANDBACK" if "<result>" in text else "SYSTEM", "", text
    if head.startswith(SYSTEM_TAGS) or kind not in ("human", None):
        return "SYSTEM", "", text
    if record.get("userType", "external") != "external" or record.get("isSidechain"):
        return "SYSTEM", "", text
    if "<pasted_content" in text or record.get("promptSource") == "pasted":
        return "OPERATOR", PASTED, text
    # The pilot's relay signs: the client's turn glyph, or a prompt too long to have been typed.
    if "\u273b" in text or text.count("\n") > 15 or len(text) > 2500:
        return "OPERATOR", RELAYED, text
    return "OPERATOR", "", text


def said(record, names):
    """(speaker, note, text) for each part of one transcript record that renders; names maps tool_use ids to tools."""
    kind = record.get("type")
    if kind == "attachment":
        queued = record.get("attachment")
        if isinstance(queued, dict) and queued.get("type") == "queued_command" and queued.get("prompt"):
            yield prompt(flat(queued["prompt"]), queued.get("origin"), record)
        return
    message = record.get("message")
    content = message.get("content") if isinstance(message, dict) else None
    blocks = content if isinstance(content, list) else []
    if kind == "assistant":
        for block in blocks if blocks else [{"type": "text", "text": content}]:
            if isinstance(block, dict) and block.get("type") == "text":
                yield "ASSISTANT", "", flat(block.get("text"))
            elif isinstance(block, dict) and block.get("type") == "tool_use":
                if isinstance(block.get("id"), str):
                    names[block["id"]] = block.get("name")
                yield f"CALL({block.get('name') or '?'})", "", json.dumps(block.get("input"), ensure_ascii=False)
        return
    if kind != "user":
        return
    origin = record.get("origin")
    if record.get("isCompactSummary"):
        yield "SYSTEM", SUMMARY, flat(content)
    elif record.get("isMeta") and not (isinstance(origin, dict) and origin.get("kind") == "peer"):
        return
    elif any(isinstance(block, dict) and block.get("type") == "tool_result" for block in blocks):
        for block in blocks:
            if isinstance(block, dict) and block.get("type") == "tool_result":
                tool = block.get("tool_use_id")
                name = names.get(tool) if isinstance(tool, str) else None
                yield f"RESULT({name or '?'})", ERROR if block.get("is_error") else "", flat(block.get("content"))
            elif isinstance(block, dict) and block.get("type") == "text":
                yield prompt(flat(block.get("text")), origin, record)
    else:
        yield prompt(flat(content), origin, record)


def fit(record, max_record):
    """The record, or its head cut so the rendered record stays within max_record bytes; and the characters cut."""
    if len(record.rendered.encode()) <= max_record:
        return record, 0
    room = max_record - len(replace(record, text="").rendered.encode()) - len(CUT.format(len(record.text)).encode())
    kept = record.text.encode()[:max(room, 0)].decode(errors="ignore")
    cut = len(record.text) - len(kept)
    return replace(record, text=kept + CUT.format(cut)), cut


def render(path, max_record=MAX_RECORD):
    """Every record whole and redacted; a line that is not a JSON object is skipped and counted."""
    path = Path(path)
    records, cuts, counts, names = [], [], {}, {}
    skipped = size = 0
    with path.open("rb") as fh:
        for number, raw in enumerate(fh, 1):
            size += len(raw)
            if not raw.strip():
                continue
            try:
                record = json.loads(raw)
            except (ValueError, RecursionError):
                record = None
            if not isinstance(record, dict):
                skipped += 1
                continue
            time = when(record.get("timestamp"))
            for speaker, note, text in said(record, names):
                body = SURROGATE.sub("\ufffd", text).strip()
                if body:
                    entry, cut = fit(Record(number, time, speaker, redact(note + body, counts)), max_record)
                    records.append(entry)
                    if cut:
                        cuts.append((number, cut))
    return Rendered("\n".join(r.rendered for r in records), records, cuts, skipped, size, path.stem, counts)
