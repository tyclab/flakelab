#!/usr/bin/env python3
"""A stand-in for Codex's shared app server, for the suites of codex_threads.py.

It listens on $CODEX_HOME/app-server-control/app-server-control.sock, speaks the same
WebSocket and JSON messages, and keeps state: conversations, turns, background
terminals and the projects table. Its answers are built from exchanges recorded
on a real server (testdata/codex-app-server/<version>/exchanges.json), so they
carry the fields the real one sends and no others.

A test drives it in-process (FakeCodex) and reads `log`, the requests it got. The
zsh suite starts it as a program:

    codex_fake_server.py <codex home> [scenario.json]

It prints "ready" once it listens and writes every request as one JSON line to
<codex home>/requests.jsonl. A scenario file sets attributes of FakeCodex by name.
"""

import base64
import copy
import hashlib
import json
import os
from pathlib import Path
import socket
import sys
import threading
import time

VERSION = "0.169.0"
GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
DATA = Path(__file__).with_name("testdata") / "codex-app-server" / VERSION
ACTIVE = ("working", "approval", "question")


def accept_for(key):
    return base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()


def frame(opcode, payload, fin=True):
    """One server frame: not masked, as the real server sends them."""
    head = bytes([(0x80 if fin else 0) | opcode])
    n = len(payload)
    if n < 126:
        head += bytes([n])
    elif n < 65536:
        head += bytes([126]) + n.to_bytes(2, "big")
    else:
        head += bytes([127]) + n.to_bytes(8, "big")
    return head + payload


class FakeCodex:
    def __init__(self, home):
        self.exchanges = json.loads((DATA / "exchanges.json").read_text(encoding="utf-8"))
        self.home = Path(home)
        self.path = self.home / "app-server-control" / "app-server-control.sock"
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.log = []  # (method, params) of every request, in order
        self.lock = threading.Lock()
        # State.
        self.config = {"model": "gpt-6-astra", "model_reasoning_effort": "high"}
        self.projects = {}  # path -> trust level
        self.models = copy.deepcopy(self.exchanges["model-list"]["answer"]["result"]["data"])
        self.threads = {}  # id -> {"state", "model", "effort", "name", "cwd", "parent", "turns": [[id, status]]}
        self.terminals = {}  # thread id -> [command]
        self.archived = []
        self.counter = 0
        # Behaviour a case can set.
        self.page_size = 0  # model/list and terminal lists in pages of this many (0: one page)
        self.auto_trust = False  # thread/start saves a trust entry for cwd, as Codex does
        self.echo = {}  # overrides of thread/start's echoed "model" / "reasoningEffort"
        self.fail = {}  # method -> list of "error", "silent" or "drop:<key>", used up one per call
        self.unknown = set()  # methods this server does not have
        self.fragment = False  # answers in two fragments with a ping between
        self.noise = False  # a notification and a server request before each answer
        self.stubborn = False  # an interrupt is accepted and the turn keeps running
        self.sticky = False  # a clean is accepted and the terminals stay
        self.turn_changes = 0  # the active turn is replaced this many times before an interrupt
        self.stall_after = None  # answer this many thread/read, then stop answering them
        self.reads = 0
        self.delay = 0.0  # seconds every answer takes
        self.deaf_after = None  # after this many messages the server stops reading, for deaf_seconds
        self.deaf_seconds = 6.0
        self.repeat_cursor = False  # a paged list names the same next page for ever
        self.no_parent = set()  # thread ids whose answers lack parentThreadId
        self.ghosts = []  # thread ids listed as loaded once and never readable: unloaded in between
        self.flip = {}  # thread id -> [reads answered as it is, the state from then on]
        self.reads_of = {}
        self.projects_shape = "table"  # or "absent", "null", "list": what config/read carries as projects
        self.bad_accept = False
        self.sink = None  # type: ignore[assignment]  # file: one JSON line per request (program mode)
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.bind(str(self.path))
        self.sock.listen(8)
        self.running = True
        threading.Thread(target=self._accept, daemon=True).start()

    # -- state helpers a case uses -------------------------------------------------

    def add_thread(self, tid, state="idle", parent=None, model="gpt-6-luna", effort="low", cwd="/work/lane", name=None, turn=None):
        # An older, finished turn first: only the newest one may be interrupted.
        turns = [[f"old-{tid[:8]}", "completed"], [turn or f"turn-{tid[:8]}", "inProgress" if state in ACTIVE else "completed"]]
        self.threads[tid] = {"state": state, "model": model, "effort": effort, "name": name, "cwd": cwd, "parent": parent, "turns": turns}
        return tid

    def methods(self):
        return [m for m, _ in self.log]

    def stop(self):
        self.running = False
        try:
            self.sock.close()
        finally:
            if self.path.exists():
                self.path.unlink()

    # -- transport -------------------------------------------------------------------

    def _accept(self):
        while self.running:
            try:
                conn, _ = self.sock.accept()
            except OSError:
                return
            threading.Thread(target=self._serve, args=(conn,), daemon=True).start()

    def _serve(self, conn):
        try:
            head = b""
            while b"\r\n\r\n" not in head:
                chunk = conn.recv(1)
                if not chunk:
                    return
                head += chunk
            key = ""
            for line in head.decode().split("\r\n"):
                if line.lower().startswith("sec-websocket-key:"):
                    key = line.split(":", 1)[1].strip()
            accept = "AAAAAAAAAAAAAAAAAAAAAAAAAAA=" if self.bad_accept else accept_for(key)
            conn.sendall(
                (
                    "HTTP/1.1 101 Switching Protocols\r\nconnection: Upgrade\r\nupgrade: websocket\r\n"
                    f"sec-websocket-accept: {accept}\r\nx-codex-websocket-max-unfragmented-message-bytes: 16777216\r\n\r\n"
                ).encode()
            )
            session = {"experimental": False}
            handled = 0
            while True:
                if self.deaf_after is not None and handled >= self.deaf_after:
                    time.sleep(self.deaf_seconds)
                    return
                message = self._read(conn)
                if message is None:
                    return
                self._handle(conn, session, json.loads(message))
                handled += 1
        except OSError:
            return
        finally:
            conn.close()

    def _read(self, conn):
        def exact(n):
            data = b""
            while len(data) < n:
                chunk = conn.recv(n - len(data))
                if not chunk:
                    raise OSError("closed")
                data += chunk
            return data

        b0, b1 = exact(2)
        if not b1 & 0x80:
            raise OSError("a client frame must be masked")
        n = b1 & 0x7F
        if n == 126:
            n = int.from_bytes(exact(2), "big")
        elif n == 127:
            n = int.from_bytes(exact(8), "big")
        mask = exact(4)
        payload = bytes(b ^ mask[i % 4] for i, b in enumerate(exact(n)))
        if b0 & 0x0F == 0x8:
            return None
        if b0 & 0x0F == 0xA:
            return self._read(conn)
        return payload.decode()

    def _send(self, conn, obj):
        payload = json.dumps(obj).encode()
        if self.fragment and len(payload) > 2:
            half = len(payload) // 2
            conn.sendall(frame(0x1, payload[:half], fin=False) + frame(0x9, b"ping") + frame(0x0, payload[half:]))
        else:
            conn.sendall(frame(0x1, payload))

    # -- protocol --------------------------------------------------------------------

    def _handle(self, conn, session, message):
        method, params, rid = message.get("method"), message.get("params") or {}, message.get("id")
        with self.lock:
            self.log.append((method, params))
            if self.sink:
                self.sink.write(json.dumps({"method": method, "params": params}) + "\n")
                self.sink.flush()
        if rid is None:
            return
        # Plans. Before the request takes effect: "silent" (it never arrives), "error". After
        # it took effect: "lost" (no answer), "close" (the connection ends), "garbage" (an
        # answer that is no JSON), "drop:<path>" (an answer without that field).
        planned = self.fail.get(method) or []
        plan = planned.pop(0) if planned else ""
        if plan == "silent":
            return
        if self.delay:
            time.sleep(self.delay)
        if self.noise:
            self._send(conn, {"method": "thread/status/changed", "params": {"threadId": "x"}})
            self._send(conn, {"method": "item/commandExecution/requestApproval", "id": rid, "params": {}})
        if plan == "error":
            self._send(conn, {"id": rid, "error": {"code": -32603, "message": f"{method} failed on purpose"}})
            return
        if method in self.unknown:
            answer = copy.deepcopy(self.exchanges["unknown-method"]["answer"])
            answer["error"]["message"] = answer["error"]["message"].replace("flakelab/noSuchMethod", method)
            self._send(conn, {"id": rid, **answer})
            return
        try:
            with self.lock:
                result = self._result(session, method, params)
        except LookupError as err:
            self._send(conn, {"id": rid, "error": {"code": -32600, "message": str(err)}})
            return
        if result is None or plan == "lost":
            return
        if plan == "close":
            conn.sendall(frame(0x8, b""))
            raise OSError("closed on purpose")
        if plan == "garbage":
            conn.sendall(frame(0x1, b"{this is no json"))
            return
        if plan.startswith("drop:"):
            target = result
            *path, last = plan[5:].split(".")
            for key in path:
                target = target[key]
            target.pop(last, None)
        self._send(conn, {"id": rid, "result": result})

    def _thread_object(self, tid, sample="thread-read-idle"):
        t = self.threads[tid]
        obj = copy.deepcopy(self.exchanges[sample]["answer"]["result"]["thread"])
        status = {
            "idle": {"type": "idle"},
            "working": {"type": "active", "activeFlags": []},
            "approval": {"type": "active", "activeFlags": ["waitingOnApproval"]},
            "question": {"type": "active", "activeFlags": ["waitingOnUserInput"]},
            "both": {"type": "active", "activeFlags": ["waitingOnUserInput", "waitingOnApproval"]},
            "unloaded": {"type": "notLoaded"},
            "error": {"type": "systemError"},
            "strange": {"type": "somethingNew"},
        }[t["state"]]
        obj.update(id=tid, sessionId=tid, status=status, model=t["model"], reasoningEffort=t["effort"], name=t["name"], cwd=t["cwd"], parentThreadId=t["parent"])
        if tid in self.no_parent:
            del obj["parentThreadId"]
        return obj

    def _need(self, tid, loaded=False):
        if tid not in self.threads:
            raise LookupError(f"thread not loaded: {tid}")
        if loaded and self.threads[tid]["state"] == "unloaded":
            raise LookupError(f"thread not found: {tid}")
        return self.threads[tid]

    def _page(self, items, params):
        if self.repeat_cursor:
            return items[:1], "again"
        start = int(params.get("cursor") or 0)
        if not self.page_size:
            return items, None
        end = start + self.page_size
        return items[start:end], (str(end) if end < len(items) else None)

    def _result(self, session, method, params):
        x = self.exchanges
        if method == "initialize":
            session["experimental"] = bool((params.get("capabilities") or {}).get("experimentalApi"))
            return copy.deepcopy(x["initialize"]["answer"]["result"])
        if method == "config/read":
            result = copy.deepcopy(x["config-read"]["answer"]["result"])
            result["config"].update(self.config)
            result["config"]["projects"] = {k: {"trust_level": v} for k, v in self.projects.items()}
            if self.projects_shape == "absent":
                del result["config"]["projects"]
            elif self.projects_shape != "table":
                result["config"]["projects"] = None if self.projects_shape == "null" else ["not", "a", "table"]
            return result
        if method == "model/list":
            data, cursor = self._page(self.models, params)
            return {"data": copy.deepcopy(data), "nextCursor": cursor}
        if method == "thread/start":
            self.counter += 1
            tid = f"aaaaaaaa-0000-7000-8000-{self.counter:012d}"
            self.threads[tid] = {"state": "idle", "model": params.get("model"), "effort": (params.get("config") or {}).get("model_reasoning_effort"), "name": None, "cwd": params.get("cwd"), "parent": None, "turns": []}
            if self.auto_trust:
                self.projects[params["cwd"]] = "trusted"
            result = copy.deepcopy(x["thread-start"]["answer"]["result"])
            result.update(model=params.get("model"), reasoningEffort=self.threads[tid]["effort"], cwd=params.get("cwd"))
            result.update(self.echo)
            result["thread"] = self._thread_object(tid, "thread-read-fresh")
            return result
        if method == "thread/name/set":
            self._need(params["threadId"])["name"] = params["name"]
            return {}
        if method == "turn/start":
            t = self._need(params["threadId"])
            self.counter += 1
            turn = f"bbbbbbbb-0000-7000-8000-{self.counter:012d}"
            t["turns"].append([turn, "inProgress"])
            t["state"] = "working"
            t["model"], t["effort"] = params.get("model", t["model"]), params.get("effort", t["effort"])
            result = copy.deepcopy(x["turn-start"]["answer"]["result"])
            result["turn"].update(id=turn, rootTurnId=turn)
            return result
        if method == "thread/read":
            self.reads += 1
            if self.stall_after is not None and self.reads > self.stall_after:
                return None
            tid = params["threadId"]
            t = self._need(tid)
            count = self.reads_of[tid] = self.reads_of.get(tid, 0) + 1
            if tid in self.flip and count > self.flip[tid][0]:
                t["state"] = self.flip[tid][1]
            return {"thread": self._thread_object(tid)}
        if method == "thread/turns/list":
            t = self._need(params["threadId"])
            # Oldest first unless asked otherwise, and every turn unless a limit is given:
            # a caller that wants the newest one has to say so.
            sample = x["turns-list-active"]["answer"]["result"]
            turns = [{**copy.deepcopy(sample["data"][0]), "id": i, "rootTurnId": i, "status": status} for i, status in t["turns"]]
            if params.get("sortDirection") == "desc":
                turns.reverse()
            if isinstance(params.get("limit"), int):
                turns = turns[: params["limit"]]
            return {**sample, "data": turns}
        if method == "thread/loaded/list":
            loaded = [tid for tid, t in self.threads.items() if t["state"] != "unloaded"]
            loaded, self.ghosts = self.ghosts + loaded, []
            data, cursor = self._page(loaded, params)
            return {"data": data, "nextCursor": cursor}
        if method in ("thread/backgroundTerminals/list", "thread/backgroundTerminals/clean"):
            if not session["experimental"]:
                raise LookupError(f"{method} requires experimentalApi capability")
            self._need(params["threadId"], loaded=True)
            if method.endswith("clean"):
                if not self.sticky:
                    self.terminals[params["threadId"]] = []
                return {}
            entry = x["terminals-list"]["answer"]["result"]["data"][0]
            items = [{**entry, "command": c} for c in self.terminals.get(params["threadId"], [])]
            data, cursor = self._page(items, params)
            return {"data": data, "nextCursor": cursor}
        if method == "turn/interrupt":
            t = self._need(params["threadId"])
            if self.turn_changes > 0:
                self.turn_changes -= 1
                self.counter += 1
                t["turns"][-1][1] = "completed"
                t["turns"].append([f"bbbbbbbb-0000-7000-8000-{self.counter:012d}", "inProgress"])
            active = t["turns"][-1] if t["turns"] and t["turns"][-1][1] == "inProgress" else None
            if active is None:
                raise LookupError("no active turn to interrupt")
            if active[0] != params["turnId"]:
                raise LookupError(f"expected active turn id {params['turnId']} but found {active[0]}")
            if not self.stubborn:
                active[1] = "interrupted"
                t["state"] = "idle"
            return {}
        if method == "thread/archive":
            self._need(params["threadId"])
            self.archived.append(params["threadId"])
            return {}
        raise LookupError(f"Invalid request: unknown variant `{method}`")


def main():
    home = sys.argv[1]
    fake = FakeCodex(home)
    fake.sink = open(os.path.join(home, "requests.jsonl"), "a", encoding="utf-8")
    if len(sys.argv) > 2:
        scenario = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
        for tid, t in scenario.pop("threads", {}).items():
            fake.add_thread(tid, **t)
        for key, value in scenario.items():
            setattr(fake, key, value)
    print("ready", flush=True)
    try:
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        fake.stop()


if __name__ == "__main__":
    main()
