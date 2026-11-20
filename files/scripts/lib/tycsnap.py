"""Pane metadata in flakelab sessions' existing per-boot autosave."""

import fcntl
import json
import os
import re
import subprocess
import sys
import tempfile
import unicodedata
from uuid import uuid4
from datetime import datetime
from pathlib import Path

MARKER = "# tycsnap "
US = "\x1f"
UUID = re.compile(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}", re.I)
PROC = Path(os.environ.get("FLAKELAB_PROC_ROOT", "/proc"))


def uuid(value):
    value = value.strip("{}").lower()
    return value if UUID.fullmatch(value) else ""


def valid_title(title):
    return not any(unicodedata.category(char) == "Cc" for char in title)


def token_valid(token):
    boot, _, pane = token.partition("/")
    return bool(re.fullmatch(r"[a-f0-9]{12}", boot) and uuid(pane) == pane and pane)


def proc_stat(pid, root=PROC):
    try:
        # ppid, process group, foreground group and start ticks follow comm.
        fields = (root / str(pid) / "stat").read_text().rsplit(") ", 1)[1].split()
        return (fields[1], fields[2], fields[5], fields[19])
    except (OSError, IndexError, ValueError):
        return None


def client_pane(pid, panes):
    try:
        env = (PROC / str(pid) / "environ").read_bytes().split(b"\0")
    except OSError:
        return ""
    ident = next((uuid(e[11:].decode("ascii", "ignore")) for e in env if e.startswith(b"WT_SESSION=")), "")
    pane = panes.get(ident)
    if not pane:
        return ""
    # A server, a background job, or a session in an old tmux pane may have
    # inherited WT_SESSION. Only the registered shell's foreground tree counts.
    stat = proc_stat(pid)
    if not stat or stat[1] != stat[2]:
        return ""
    seen = set()
    while pid and pid not in seen:
        seen.add(pid)
        stat = proc_stat(pid)
        if not stat:
            break
        if [pid, stat[3]] == pane["owner"]:
            return ident
        pid = stat[0]
    return ""


def descends_from(pid, ancestor):
    seen = set()
    while pid and pid not in seen:
        if pid == ancestor:
            return True
        seen.add(pid)
        stat = proc_stat(pid)
        if not stat:
            break
        pid = stat[0]
    return False


def read(path):
    try:
        lines = path.read_text().splitlines()
    except FileNotFoundError:
        lines = []
    state = {"panes": {}, "used": {}}
    for line in lines:
        if line.startswith(MARKER):
            state = json.loads(line[len(MARKER):])
    # Older pane snapshots used the native launch argument or tmux lane tag.
    # Neither identifies what a shared client displayed after switching tasks.
    for pane in state["panes"].values():
        agent = pane.get("agent", {})
        if agent.get("tool") == "codex" and not agent.get("native"):
            pane.pop("agent")
    return state, [line for line in lines if not line.startswith("#")]


def prior(path, prefix):
    candidates = [p for p in path.parent.glob(prefix + "*.txt") if p != path]
    return max(candidates, key=lambda p: p.stat().st_mtime_ns, default=None)


def boot_of(path, prefix):
    return path.stem.removeprefix(prefix)


def atomically_save(path, box, boot, state, lines, keep):
    fd, temp = tempfile.mkstemp(dir=path.parent, prefix="." + path.name + ".flakelab-tmp.")
    try:
        with os.fdopen(fd, "w") as stream:
            distro = os.environ.get("WSL_DISTRO_NAME")
            header = "# claude-sessions autosave " + box + (f" distro={distro}" if distro else "")
            print(header, f"boot={boot}", datetime.now().astimezone().isoformat(timespec="seconds"), file=stream)
            if state["panes"] or state.get("offered") or state["used"] or state.get("launches"):
                print(MARKER + json.dumps(state, ensure_ascii=True, separators=(",", ":")), file=stream)
            for line in lines:
                print(line, file=stream)
        os.replace(temp, path)
    finally:
        Path(temp).unlink(missing_ok=True)
    older = sorted(path.parent.glob(box + "-autosave-*.txt"), key=lambda p: p.stat().st_mtime_ns, reverse=True)
    for old in [p for p in older if p != path][keep - 1:]:
        old.unlink(missing_ok=True)


def set_foreground(pane, agents, host=None):
    view = {"tmux": host} if host else {}
    if len(agents) == 1 and agents[0]:
        view["agent"] = agents[0]
    if pane.get("pending"):
        # The requested target stays available if native startup fails. A
        # tab closed during the running restore recovers its observed view.
        if active_attempt(pane):
            pane["observed"] = view
    else:
        apply_view(pane, view)


def apply_view(pane, view):
    pane.pop("agent", None)
    pane.pop("tmux", None)
    pane.update(view)


def foreground(rows, panes, boot):
    agents_by_pid = {}
    direct = {}
    for pane in panes.values():
        pid, start = pane["owner"]
        stat = proc_stat(pid)
        # A dead or hung-up shell keeps its last foreground for recovery.
        # An attached shell reflects this scan, including an ambiguous result.
        if stat and stat[3] == start and int(stat[2]) > 0 and not pane.get("pending"):
            pane.pop("agent", None)
            pane.pop("tmux", None)
    for row in rows:
        tool, pid, _, sid, cwd, wid, _, group, profile = row.split(US)
        agent = None
        if uuid(sid):
            agent = dict(tool=tool, session=sid, cwd=cwd, group=group, profile=profile)
            if tool == "codex":
                agent["native"] = True
        agents_by_pid.setdefault(pid, []).append(agent)
        if not wid and (ident := client_pane(pid, panes)):
            direct.setdefault(ident, []).append(agent)
    for ident, agents in direct.items():
        set_foreground(panes[ident], agents)
    # For hosted agents only the attached client belongs to a terminal. The
    # server and its children keep the environment from the day it started.
    fields = ["client_pid", "pid", "session_name", "window_id", "window_name", "pane_pid"]
    try:
        clients = subprocess.run(["tmux", "list-clients", "-F", US.join("#{%s}" % k for k in fields)],
                                 capture_output=True, text=True, check=False)
    except FileNotFoundError:
        return
    for line in clients.stdout.splitlines():
        parts = line.split(US)
        if len(parts) != 6:
            continue
        pid, server, session, wid, name, active = parts
        ident = client_pane(pid, panes)
        stat = proc_stat(server)
        if not ident or not stat or not re.fullmatch(r"@[0-9]+", wid):
            continue
        pane = panes[ident]
        host = dict(boot=boot, server=[server, stat[3]], session=session, window=wid, name=name)
        # tmux tells us which pane is selected, even when a split window
        # or a session outside the managed agents group contains other tools.
        agents = [agent for pid, group in agents_by_pid.items() if descends_from(pid, active) for agent in group]
        set_foreground(pane, agents, host)


def command(path, box, boot, keep, op, args):
    state, lines = read(path)
    before = json.dumps([state, lines], sort_keys=True)
    panes, used = state["panes"], state["used"]
    prefix = box + "-autosave-"
    response = None
    if op == "autosave":
        # Both sets come from one gather() pass. The legacy lines remain
        # untouched on an empty timer tick, including after a crash.
        data = sys.stdin.buffer.read().decode().split("\0")
        boundary = data.index("")
        recorded, rows = data[:boundary], [r for r in data[boundary + 1:] if r]
        if recorded:
            lines = sorted(recorded)
        if panes:
            foreground(rows, panes, boot)
    elif op == "launch":
        # --open knows what it wants before Windows allocates a pane id.
        # Only an opaque token crosses Windows' command-line parser.
        tool, cwd, sid, group, profile, wid, view, server_pid = args
        if tool not in ("claude", "codex") or not uuid(sid):
            raise ValueError("saved session has no native id")
        name = Path(cwd).name
        record = dict(cwd=cwd, name=name if valid_title(name) else "",
                      agent=dict(tool=tool, cwd=cwd, session=sid, group=group, profile=profile))
        if tool == "codex":
            record["agent"]["native"] = True  # --open explicitly requested this UUID.
        if wid:
            server = proc_stat(server_pid)
            if not re.fullmatch(r"@[0-9]+", wid) or not server:
                raise ValueError("tmux server exited before the tab could open")
            record["tmux"] = dict(boot=boot, server=[server_pid, server[3]], window=wid, view=view)
        launches = state.setdefault("launches", {})
        key = next((k for k, v in launches.items() if v == record), str(uuid4()))
        launches[key] = record
        response = boot + "/" + key
    elif op == "discard":
        state.get("launches", {}).pop(args[0].partition("/")[2], None)
    else:
        ident = uuid(os.environ.get("WT_SESSION", ""))
        owner = os.environ.get("FLAKELAB_TYCSNAP_OWNER", "")
        stat = proc_stat(owner) if owner.isdecimal() else None
        manual = not stat and op in ("take", "available", "reserve", "release") and not owner
        if not ident or (not stat and not manual):
            raise ValueError("TycSnap needs a registered Windows Terminal shell")
        owner = [owner, stat[3]] if stat else None
        pane = panes.get(ident, {})
        if not manual and pane and pane["owner"] != owner and is_alive(pane):
            raise ValueError("this Windows Terminal pane already has a registered shell")
        if op == "enter":
            old = prior(path, prefix)
            previous, previous_lines = read(old) if old else ({"panes": {}}, [])
            first = not state.get("offered")
            state["offered"] = True
            token = os.environ.get("FLAKELAB_TYCSNAP_SOURCE", "")
            source_boot, _, source_id = token.partition("/")
            restored = None
            if pane and pane["owner"] != owner:
                restored = pane
                used[boot + "/" + ident] = ident
            # Terminal persists the startup command as well as WT_SESSION.
            # After a fallback tab has been edited, its own id takes precedence
            # over the original source token still present on that command.
            if old and (not token or ident in previous["panes"]):
                source_boot, source_id = boot_of(old, prefix), ident
            source = panes if source_boot == boot else previous["panes"] if old and source_boot == boot_of(old, prefix) else {}
            key = source_boot + "/" + source_id
            launch_state = state if source_boot == boot else previous if old and source_boot == boot_of(old, prefix) else {}
            if not restored and token and source_id in launch_state.get("launches", {}) and key not in used:
                restored = launch_state["launches"][source_id]
                if restored.get("agent", {}).get("tool") == "codex":
                    # An unclaimed --open request can predate the pane format.
                    restored["agent"]["native"] = True
                used[key] = ident
                if source_boot == boot:
                    del launch_state["launches"][source_id]
            if not restored and source_id in source and used.get(key) in (None, "opening", ident):
                restored = source[source_id]
                used[key] = ident
                if source_boot == boot and source_id != ident:
                    del panes[source_id]
            if not restored and token_valid(token) and used.get(token) not in (None, "opening", ident):
                # A manually retried Windows launch may arrive after the
                # first launch has already claimed exactly this source.
                response = {"action": "superseded"}
            elif pane and pane["owner"] == owner:
                response = {}
            else:
                pane = dict(restored or {}, owner=owner)
                if "observed" in pane:
                    apply_view(pane, pane.pop("observed"))
                pane.pop("attempt", None)
                pane.setdefault("cwd", os.getcwd())
                if not valid_title(pane.setdefault("name", "")):
                    pane["name"] = ""
                panes[ident] = pane
                if restored:
                    pane["pending"] = True
                    response = dict(action="restore", cwd=pane["cwd"], name=pane["name"])
                elif first and old and (previous["panes"] or (previous_lines and not previous.get("offered"))):
                    response = {"action": "offer"}
                else:
                    response = {}
        elif not manual and (not pane or pane["owner"] != owner):
            raise ValueError("this shell does not own this Windows Terminal pane")
        elif op == "name":
            name, = args
            if not valid_title(name):
                raise ValueError("tab titles must not contain terminal control characters")
            pane["name"] = name
        elif op == "update":
            pane["cwd"], = args
            response = pane["name"]
            if not pane.get("pending"):
                pane.pop("agent", None)
                pane.pop("tmux", None)
        elif op == "exit":
            del panes[ident]
        elif op == "take":
            response = {}
            if not manual and pane.get("pending"):
                host = pane.get("tmux", {})
                server = host.get("server", [])
                live = host.get("boot") == boot and bool(server) and is_alive({"owner": server})
                # Two saved views on the same dead window must not both start
                # its conversation. Two views on a live window can reattach.
                same = [pane] if live or not pane.get("agent") else [
                    other for other in panes.values() if other.get("agent") == pane["agent"]
                ]
                if any(active_attempt(other) for other in same):
                    response = {"busy": True}
                else:
                    worker = proc_stat(args[0], Path("/proc"))
                    if not worker:
                        raise ValueError("restore process exited")
                    pane["attempt"] = [args[0], worker[3]]
                    response = pane.copy()
                    response["live"] = live
        elif op == "finish":
            if pane.get("attempt", [""])[0] == args[0]:
                pane.pop("attempt")
                observed = pane.pop("observed", None)
                if args[1] == "0":
                    if observed is not None:
                        apply_view(pane, observed)
                    pane.pop("pending", None)
        elif op in ("available", "reserve"):
            old = prior(path, prefix)
            previous, previous_lines = read(old) if old else ({"panes": {}}, [])
            # The explicit menu may also recover a tab closed during this boot.
            candidates = {boot + "/" + k: v for k, v in panes.items() if not is_alive(v)}
            if old:
                candidates.update({boot_of(old, prefix) + "/" + k: v for k, v in previous["panes"].items()})
            tokens = [k for k in candidates if token_valid(k) and
                      (k not in used or (args == ["retry"] and used[k] == "opening"))]
            legacy = str(old) if old and not previous.get("offered") and previous_lines and "legacy" not in used else ""
            response = {"tokens": tokens, "legacy": legacy}
            if op == "reserve":
                used.update({k: "opening" for k in tokens})
                if legacy:
                    used["legacy"] = ident
        elif op == "release":
            if used.get(args[0]) in ("opening", ident):
                used.pop(args[0])
        else:
            raise ValueError("unknown TycSnap operation")
    if before != json.dumps([state, lines], sort_keys=True):
        atomically_save(path, box, boot, state, lines, keep)
        if op == "autosave":
            print(f"autosaved {len(lines)} session(s) to {path}", file=sys.stderr)
    if response is not None:
        print(response if op in ("update", "launch") else json.dumps(response))


def active_attempt(pane):
    attempt = pane.get("attempt", [])
    stat = proc_stat(attempt[0], Path("/proc")) if attempt else None
    return bool(stat and stat[3] == attempt[1])


def is_alive(pane):
    pid, start = pane["owner"]
    stat = proc_stat(pid)
    return bool(stat and stat[3] == start)


def main():
    directory, box, boot, keep, op, *args = sys.argv[1:]
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    # The local lock is stable across snapshot replacements and stays out of sync.
    local = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")) / "flakelab"
    local.mkdir(parents=True, exist_ok=True)
    with (local / "tycsnap.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        command(directory / f"{box}-autosave-{boot}.txt", box, boot, int(keep), op, args)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError) as exc:
        sys.exit(f"TycSnap: {exc}")
