"""Shared stdio MCP question tool for Claude and Codex; no background observer."""

import itertools
import json
import os
from pathlib import Path
import secrets
import shlex
import socket
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

INSTRUCTIONS = (
    "Use flakelab-questions ask_question when you need the user's clarification or "
    "decision. It retains the full question in Home Assistant and waits for their "
    "answer from the phone or inbox. In an interactive terminal the same question "
    "also opens as a dialog; the first answer, terminal or phone, wins. "
    "Ask once and use the returned answer. "
    "If unavailable, cancelled or expired, ask in the conversation; never invent an "
    "answer. This tool cannot grant tool permissions or bypass approval policies."
)
TOOL = {
    "name": "ask_question",
    "description": INSTRUCTIONS,
    "inputSchema": {
        "type": "object",
        "properties": {
            "question": {"type": "string", "minLength": 1, "maxLength": 12000},
            "context": {"type": "string", "maxLength": 24000,
                        "description": "Relevant details the user needs to decide. Do not include secrets."},
            "options": {"type": "array", "maxItems": 8, "uniqueItems": True,
                        "items": {"type": "string", "minLength": 1, "maxLength": 300}},
        },
        "required": ["question"],
        "additionalProperties": False,
    },
    "annotations": {"readOnlyHint": False, "destructiveHint": False,
                    "idempotentHint": False, "openWorldHint": True},
}


def endpoint():
    value = os.environ.get("NOTIFY_WEBHOOK_URL", "")
    if not value:
        for name in (os.environ.get("FLAKELAB_SECRETS_ENV", ""),
                     os.environ.get("FLAKELAB_SECRETS_RENDER", "/run/secrets/flakelab-env"),
                     str(Path.home() / ".config/flakelab/secrets.env")):
            if not name:
                continue
            try:
                lines = Path(name).read_text().splitlines()
            except OSError:
                continue
            for line in lines:
                if line.startswith("export "):
                    line = line[7:]
                key, sep, raw = line.partition("=")
                if sep and key.strip() == "NOTIFY_WEBHOOK_URL":
                    parts = shlex.split(raw, comments=True)
                    value = parts[0] if len(parts) == 1 else ""
            break
    parsed = urllib.parse.urlsplit(value)
    if (parsed.scheme not in ("http", "https") or not parsed.netloc
            or not parsed.path.startswith("/api/webhook/") or parsed.query or parsed.fragment):
        raise ValueError("Question inbox is not configured: set NOTIFY_WEBHOOK_URL.")
    return value + "-questions"


class ProtocolError(ValueError):
    """The inbox answered HTTP 400: it does not accept this request (old hatyc or bad input)."""


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class Transport:
    def __init__(self):
        self.url = endpoint()
        self.opener = urllib.request.build_opener(NoRedirect)

    def post(self, payload):
        request = urllib.request.Request(self.url, json.dumps(payload, ensure_ascii=False).encode(),
                                         {"Content-Type": "application/json"})
        try:
            with self.opener.open(request, timeout=10) as response:
                body = json.load(response)
            if not isinstance(body, dict) or "status" not in body:
                raise ValueError("Question inbox returned an invalid response.")
            return body
        except urllib.error.HTTPError as exc:
            # urllib exceptions can contain the secret webhook URL.
            if exc.code == 400:
                raise ProtocolError("Question inbox rejected the request.") from None
            raise ConnectionError("Question inbox is unreachable or incompatible.") from None
        except (urllib.error.URLError, OSError, ValueError):
            raise ConnectionError("Question inbox is unreachable or incompatible.") from None


def validate(arguments):
    if not isinstance(arguments, dict) or set(arguments) - {"question", "context", "options"}:
        raise ValueError("Expected question, optional context and options.")
    for key, limit, required in (("question", 12000, True), ("context", 24000, False)):
        value = arguments.get(key, "")
        if not isinstance(value, str) or len(value) > limit or (required and not value.strip()):
            raise ValueError(f"Invalid {key}.")
    options = arguments.get("options", [])
    if (not isinstance(options, list) or len(options) > 8
            or any(not isinstance(x, str) or not x.strip() or len(x) > 300 for x in options)
            or len(set(options)) != len(options)):
        raise ValueError("Invalid options.")
    return arguments


def dialog_schema(question):
    """Elicitation form: a choice list beside free text when there are options, free text alone otherwise."""
    answer = {"type": "string", "title": "Or answer in your own words", "maxLength": 12000}
    options = question.get("options") or []
    if options:
        return {"type": "object", "properties": {
            "choice": {"type": "string", "title": "Choice", "enum": options, "enumNames": options},
            "answer": answer}}
    return {"type": "object", "properties": {"answer": {**answer, "title": "Answer"}}, "required": ["answer"]}


class Dialog:
    """One terminal dialog: a server-sent elicitation and the slot its reply lands in."""

    def __init__(self, ident):
        self.id, self.event, self.response, self.done = ident, threading.Event(), None, False


class Server:
    def __init__(self, agent, output=sys.stdout, transport=Transport, interval=3, timeout=1500, answer_retry=30):
        self.agent, self.output, self.transport = agent, output, transport
        self.interval, self.timeout, self.answer_retry = interval, timeout, answer_retry
        self.lock = threading.Lock()
        self.active = {}
        self.elicitation = False
        self.dialogs = {}
        self.dialog_lock = threading.Lock()
        self.ids = itertools.count(1)

    def emit(self, message):
        with self.lock:
            self.output.write(json.dumps({"jsonrpc": "2.0", **message}) + "\n")
            self.output.flush()

    def send(self, ident, result=None, error=None):
        self.emit({"id": ident, **({"error": error} if error else {"result": result})})

    def open_dialog(self, question):
        dialog = Dialog(f"q-{next(self.ids)}")
        with self.lock:
            self.dialogs[dialog.id] = dialog
        context = question.get("context", "")
        message = question["question"] + ("\n\n" + context if context else "")
        try:
            self.emit({"id": dialog.id, "method": "elicitation/create",
                       "params": {"message": message, "requestedSchema": dialog_schema(question)}})
        except (OSError, ValueError):
            with self.lock:
                self.dialogs.pop(dialog.id, None)
            self.dialog_lock.release()
            raise
        return dialog

    def close_dialog(self, dialog, cancel):
        with self.lock:
            dialog.done = True
            self.dialogs.pop(dialog.id, None)
        try:
            if cancel and dialog.response is None:
                self.emit({"method": "notifications/cancelled",
                           "params": {"requestId": dialog.id, "reason": "answered from the inbox"}})
        except (OSError, ValueError):
            pass  # stdout is gone with the client; the inbox clean-up below still matters
        finally:
            self.dialog_lock.release()

    @staticmethod
    def terminal_answer(dialog):
        """Text the operator gave in the dialog: free text first, then the choice; "" for an empty accept."""
        response = dialog.response
        if not isinstance(response, dict) or response.get("action") != "accept":
            return None
        content = response.get("content")
        if not isinstance(content, dict):
            return ""
        answer, choice = content.get("answer"), content.get("choice")
        if isinstance(answer, str) and answer.strip():
            return answer.strip()
        if isinstance(choice, str) and choice.strip():
            return choice
        return ""

    def wait(self, dialog, cancel):
        (dialog.event if dialog and not dialog.done else cancel).wait(self.interval)

    def dialog_only(self, dialog, question, cancel, deadline):
        """Wait on the dialog alone; re-show it after an empty accept. Text, or None when it was dismissed."""
        while not cancel.is_set() and time.monotonic() < deadline:
            if dialog.event.wait(self.interval):
                text = self.terminal_answer(dialog)
                self.close_dialog(dialog, cancel=False)
                if text != "" or not self.dialog_lock.acquire(blocking=False):
                    return text
                dialog = self.open_dialog(question)
        self.close_dialog(dialog, cancel=True)
        return None

    def record_terminal_answer(self, transport, auth, create, text, created, cancel):
        """Store a dialog answer in the inbox; the inbox's status decides whose answer stands."""
        payload = {"status": "answered", "answer": text, "question_id": auth["id"], "source": "terminal"}
        failures = 0
        while not created and not cancel.is_set():
            try:
                transport.post(create)
                created = True
            except ConnectionError:
                failures += 1
                if failures >= 3:
                    return {**payload, "inbox": "unavailable"}
                cancel.wait(self.interval)
        deadline = time.monotonic() + self.answer_retry
        while True:
            try:
                reply = transport.post({**auth, "op": "answer", "answer": text})
                break
            except ProtocolError:
                # An inbox without the answer op (older hatyc): at least take the push down.
                try:
                    transport.post({**auth, "op": "cancel"})
                except (ConnectionError, ValueError):
                    pass
                return {**payload, "inbox": "unsupported"}
            except ConnectionError:
                if cancel.is_set() or time.monotonic() >= deadline:
                    return {**payload, "inbox": "unavailable"}
                cancel.wait(self.interval)
        status = reply["status"]
        if status == "delivered":
            return payload
        if status == "answered":
            return {**payload, "answer": reply["answer"], "source": "inbox", "discarded_terminal_answer": text}
        raise ValueError(f"Question is {status}; no answer was returned. Ask in the conversation.")

    def ask(self, ident, arguments, cancel):
        transport = dialog = None
        auth = {"id": str(uuid.uuid4()), "token": secrets.token_hex(32)}
        finished = False
        try:
            question = validate(arguments)
            declined = False
            transport = self.transport()
            create = {**auth, "op": "create", **question, "agent": self.agent,
                      "project": os.getcwd(), "host": socket.gethostname()}
            deadline = time.monotonic() + self.timeout
            created, failures, unavailable_since = False, 0, None
            while not cancel.is_set() and time.monotonic() < deadline:
                # One dialog per server at a time: open ours as soon as the lock is free.
                if dialog is None and not declined and self.elicitation and self.dialog_lock.acquire(blocking=False):
                    dialog = self.open_dialog(question)
                if dialog and not dialog.done and dialog.event.is_set():
                    text = self.terminal_answer(dialog)
                    self.close_dialog(dialog, cancel=False)
                    dialog = None
                    if text == "":
                        continue  # Accept without a choice or text: show the dialog again.
                    if text is None:
                        declined = True
                    else:
                        payload = self.record_terminal_answer(transport, auth, create, text, created, cancel)
                        self.send(ident, {"content": [{"type": "text", "text": json.dumps(payload)}]})
                        finished = True
                        if payload["source"] == "inbox":
                            transport.post({**auth, "op": "delivered"})
                        return
                try:
                    result = transport.post({**auth, "op": "poll"} if created else create)
                    created, failures, unavailable_since = True, 0, None
                except ConnectionError:
                    failures += 1
                    unavailable_since = unavailable_since or time.monotonic()
                    if (not created and failures >= 3) or time.monotonic() - unavailable_since > 60:
                        if not (dialog and not dialog.done):
                            raise
                        # The inbox is gone but the dialog is up: let the terminal answer alone.
                        text = self.dialog_only(dialog, question, cancel, deadline)
                        dialog = None
                        if not text:
                            raise
                        self.send(ident, {"content": [{"type": "text", "text": json.dumps({
                            "status": "answered", "answer": text, "question_id": auth["id"],
                            "source": "terminal", "inbox": "unavailable"})}]})
                        finished = True
                        return
                    self.wait(dialog, cancel)
                    continue
                status = result["status"]
                if status == "answered":
                    if cancel.is_set():
                        break
                    if dialog and not dialog.done:
                        self.close_dialog(dialog, cancel=True)
                    self.send(ident, {"content": [{"type": "text", "text": json.dumps({
                        "status": "answered", "answer": result["answer"], "question_id": auth["id"],
                        "source": "inbox"})}]})
                    finished = True
                    transport.post({**auth, "op": "delivered"})
                    return
                if status != "pending":
                    raise ValueError(f"Question is {status}; no answer was returned. Ask in the conversation.")
                self.wait(dialog, cancel)
            if not cancel.is_set():
                raise ValueError("Question expired without an answer. Ask in the conversation.")
        except (ValueError, ConnectionError, KeyError, TypeError, AttributeError, OSError) as exc:
            if dialog and not dialog.done:
                self.close_dialog(dialog, cancel=True)
            if not finished and not cancel.is_set():
                self.send(ident, {"isError": True, "content": [{"type": "text", "text": str(exc)}]})
        finally:
            if dialog and not dialog.done:
                self.close_dialog(dialog, cancel=True)
            if transport and not finished:
                try:
                    transport.post({**auth, "op": "cancel"})
                except (ConnectionError, ValueError):
                    pass
            with self.lock:
                self.active.pop(ident, None)

    def handle(self, message):
        ident, method = message.get("id"), message.get("method")
        params = message.get("params") or {}
        if method == "notifications/cancelled":
            with self.lock:
                active = self.active.get(params.get("requestId"))
            if active:
                active[0].set()
        elif method is None:
            # A reply to one of our dialog requests; anything else is silently dropped.
            with self.lock:
                dialog = self.dialogs.get(ident)
            if dialog:
                dialog.response = message.get("result") or {"error": message.get("error")}
                dialog.event.set()
        elif ident is None:
            return
        elif method == "initialize":
            self.elicitation = "elicitation" in (params.get("capabilities") or {})
            self.send(ident, {"protocolVersion": "2025-06-18",
                              "capabilities": {"tools": {}},
                              "serverInfo": {"name": "flakelab-questions", "version": "1.0.0"},
                              "instructions": INSTRUCTIONS})
        elif method == "tools/list":
            self.send(ident, {"tools": [TOOL]})
        elif method == "ping":
            self.send(ident, {})
        elif method == "tools/call" and params.get("name") == TOOL["name"]:
            with self.lock:
                busy = ident in self.active or len(self.active) >= 8
                if not busy:
                    cancel = threading.Event()
                    thread = threading.Thread(target=self.ask,
                                              args=(ident, params.get("arguments"), cancel), daemon=True)
                    self.active[ident] = (cancel, thread)
            if busy:
                self.send(ident, error={"code": -32600, "message": "Too many pending questions or duplicate id."})
            else:
                thread.start()
        else:
            self.send(ident, error={"code": -32601, "message": "Unknown method or tool."})

    def run(self, source=sys.stdin):
        try:
            for line in source:
                try:
                    message = json.loads(line)
                    if not isinstance(message, dict):
                        raise ValueError()
                    self.handle(message)
                except (ValueError, TypeError, AttributeError):
                    self.send(None, error={"code": -32600, "message": "Invalid JSON-RPC request."})
        finally:
            with self.lock:
                active = list(self.active.values())
            for cancel, _ in active:
                cancel.set()
            for _, thread in active:
                thread.join(timeout=12)


if __name__ == "__main__":
    Server(os.environ.get("FLAKELAB_QUESTIONS_AGENT", "agent")).run()
