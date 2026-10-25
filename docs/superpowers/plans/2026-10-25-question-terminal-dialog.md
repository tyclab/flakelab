# ask_question terminal dialog (flakelab) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `ask_question` opens a native dialog in Claude Code and Codex through MCP elicitation while the question is posted to Home Assistant; the first answer wins and the other side closes.

**Architecture:** The single-file stdio server `files/scripts/lib/questions.py` learns to send server-initiated `elicitation/create` requests and route their replies into the waiting call. Each call keeps one `Dialog` slot; the HA poll loop checks the slot every iteration. A terminal answer is recorded in HA with the new `answer` op (hatyc), a phone answer cancels the dialog with `notifications/cancelled`. Dialogs are serialised by one lock per server process. No Nix, hook or client changes.

**Tech Stack:** Python 3 standard library only (json, threading, urllib), `unittest`; run with `./files/scripts/test-questions`; lint with `pre-commit run ruff-check --files files/scripts/lib/questions.py files/scripts/lib/test-questions.py`.

**Spec:** `docs/superpowers/specs/2026-10-25-question-terminal-dialog-design.md` (committed in Task 1).

## Global Constraints

- Protocol reply stays `"protocolVersion": "2025-06-18"`; server capabilities stay `{"tools": {}}`.
- Dialog only when the client's `initialize` carried `capabilities.elicitation`; otherwise no server-sent message at all.
- Dialog opens before the first HA post; one open dialog per server process; later calls queue.
- Schema with options: `choice` (enum + enumNames = options, title "Choice") and `answer` (string, title "Or answer in your own words", maxLength 12000), none required. Without options: `answer` required.
- `message` = question, then `"\n\n" + context` when context is non-empty.
- Result text is JSON with `status`, `answer`, `question_id`, `source` (`"terminal"` | `"inbox"`), plus `inbox` (`"unavailable"` | `"unsupported"`) and `discarded_terminal_answer` only when they apply.
- Ties go to the inbox: an `answer` op replied with `answered` returns HA's answer.
- Poll interval 3 s, answer window 1500 s, HA create gives up after 3 failures or 60 s unavailable, `answer` op retried on network failure for 30 s: all as `Server(interval=3, timeout=1500)` plus a new `answer_retry=30` argument.
- No URL or secret in any error or dialog text.

## Review Focus

- A client that advertises elicitation but replies to `elicitation/create` with a JSON-RPC error (headless or task context): the call must continue HA-only, not error (Task 4 test `test_elicitation_error_is_a_decline`).
- An answer typed with surrounding whitespace or an empty `answer` beside a chosen `choice`: the choice is used, whitespace stripped (Task 3 test `test_terminal_answer_prefers_text_then_choice`).
- A phone answer arriving between the dialog's accept and the `answer` post: HA's answer is returned, the typed text is reported, exactly one result line (Task 3 test `test_inbox_wins_a_tie`).
- The client cancelling the tool call while the dialog is open: dialog cancelled, HA cancelled, no result line (Task 4 test `test_call_cancellation_closes_dialog`).
- A second question while a dialog is open and the first is then answered from the phone: the second dialog opens within one poll interval (Task 6 test `test_dialogs_are_serialised`).

---

### Task 1: Commit the design, add `ProtocolError` to `Transport`

**Files:**

- Create: `docs/superpowers/specs/2026-10-25-question-terminal-dialog-design.md` (copy from the approved scratchpad document), `docs/superpowers/plans/2026-10-25-question-terminal-dialog.md` (this plan)
- Modify: `files/scripts/lib/questions.py:71-89` (`Transport.post`)
- Test: `files/scripts/lib/test-questions.py`

**Interfaces:**

- Produces: `class ProtocolError(ValueError)` at module level; `Transport.post` raises `ProtocolError("Question inbox rejected the request.")` on HTTP 400 and `ConnectionError(...)` (unchanged message) on every other failure.

- [ ] **Step 1: Commit the documents**

```bash
mkdir -p docs/superpowers/specs docs/superpowers/plans
cp <scratchpad>/2026-10-25-question-terminal-dialog-design.md docs/superpowers/specs/
cp <scratchpad>/2026-10-25-question-terminal-dialog.md docs/superpowers/plans/
git add docs/superpowers && git commit -m "docs(questions): design and plan for the terminal dialog"
```

- [ ] **Step 2: Write the failing test** next to `test_http_errors_never_reveal_secret_url`:

```python
    def test_http_400_is_a_protocol_error_without_the_secret(self):
        with patch.dict("os.environ", {"NOTIFY_WEBHOOK_URL": "https://ha.invalid/api/webhook/test-secret"}):
            transport = questions.Transport()
        for code, expected in ((400, questions.ProtocolError), (503, ConnectionError)):
            error = urllib.error.HTTPError(transport.url, code, "boom", {}, None)
            with patch.object(transport.opener, "open", side_effect=error):
                with self.assertRaises(expected) as raised:
                    transport.post({})
            self.assertNotIn("test-secret", str(raised.exception))
```

(add `import urllib.error` to the test imports.)

- [ ] **Step 3: Run it** — `./files/scripts/test-questions` — Expected: FAIL, `AttributeError: module 'questions' has no attribute 'ProtocolError'`.

- [ ] **Step 4: Implement**: define `ProtocolError`; in `Transport.post` catch `urllib.error.HTTPError` before the generic clause, re-raise as `ProtocolError` when `code == 400`, else fall through to the existing `ConnectionError`. Both `from None`.

- [ ] **Step 5: Run** — Expected: all tests `OK` (10).

- [ ] **Step 6: Commit** — `git commit -am "questions: tell an inbox rejection from an outage"`.

### Task 2: Capability, `Dialog` slot, and the dialog request

**Files:**

- Modify: `files/scripts/lib/questions.py:107-117` (`Server.__init__`), `:118-174` (`ask`), `:176-203` (`handle`)
- Test: `files/scripts/lib/test-questions.py`

**Interfaces:**

- Produces:
  - `Server.__init__(self, agent, output=sys.stdout, transport=Transport, interval=3, timeout=1500, answer_retry=30)`; attributes `self.elicitation = False`, `self.dialogs = {}` (request id → `Dialog`), `self.dialog_lock = threading.Lock()`, `self.ids = itertools.count(1)`.
  - `class Dialog` with `id: str` (`f"q-{n}"`), `event: threading.Event`, `response: dict | None`, `done: bool`.
  - `Server.open_dialog(self, question: dict) -> Dialog`: builds message and schema from `question` (`question`, `context`, `options`), sends `{"jsonrpc":"2.0","id":dialog.id,"method":"elicitation/create","params":{"message":..., "requestedSchema":...}}` via `self.send_request(...)` (a sibling of `send` that writes a request under the same lock), registers it in `self.dialogs`.
  - `Server.close_dialog(self, dialog, cancel: bool)`: marks done, removes from `self.dialogs`, releases `self.dialog_lock`; when `cancel` and no response arrived, sends `{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId": dialog.id, "reason": "answered from the inbox"}}`.
  - `handle()`: `initialize` sets `self.elicitation = "elicitation" in (params.get("capabilities") or {})`; a message with an `id` in `self.dialogs` and no `method` stores `result` (or `{"error": ...}`) in `dialog.response` and sets `dialog.event`; unknown ids are ignored silently (no error line).
- Test helpers (add to the test module, used by Tasks 2-6):

```python
def lines(output):
    return [json.loads(line) for line in output.getvalue().splitlines()]

def dialog_requests(output):
    return [m for m in lines(output) if m.get("method") == "elicitation/create"]

class FakeTransport:  # extend the existing one
    def __init__(self, output=None):
        ...existing...
        self.output, self.dialog_before_create = output, None
        self.answer_reply = {"status": "delivered"}
        self.fail_answer = None      # None | "protocol" | "network"
        self.down = False
    def post(self, body):
        self.calls.append(body)
        if self.down: raise ConnectionError("down")
        if body["op"] == "create" and self.dialog_before_create is None:
            self.dialog_before_create = bool(self.output and dialog_requests(self.output))
        if body["op"] == "answer":
            if self.fail_answer == "protocol": raise questions.ProtocolError("rejected")
            if self.fail_answer == "network": raise ConnectionError("down")
            return self.answer_reply
        ...existing create/poll/cancel/delivered behaviour...
```

and in `QuestionTests`: `def init(self, elicitation=True)` sends `initialize` with `{"capabilities": {"elicitation": {"form": {}, "url": {}}}}` or `{}`; `def reply(self, dialog_id, result)` calls `self.server.handle({"jsonrpc": "2.0", "id": dialog_id, "result": result})`.

- [ ] **Step 1: Write the failing tests**

```python
    def test_dialog_is_requested_before_the_inbox_when_the_client_can_show_it(self):
        self.init()
        self.start()
        [request] = dialog_requests(self.output)
        self.assertTrue(request["id"].startswith("q-"))
        self.assertEqual(request["params"]["message"], "Which colour?")
        schema = request["params"]["requestedSchema"]
        self.assertEqual(schema["properties"]["choice"]["enum"], ["Red", "Blue"])
        self.assertEqual(schema["properties"]["choice"]["enumNames"], ["Red", "Blue"])
        self.assertEqual(schema["properties"]["answer"]["maxLength"], 12000)
        self.assertNotIn("required", schema)
        self.assertTrue(self.transport.dialog_before_create)

    def test_free_text_question_requires_the_answer_field(self):
        self.init()
        self.server.handle({"id": 1, "method": "tools/call", "params": {"name": "ask_question",
                            "arguments": {"question": "Why?", "context": "Because."}}})
        self.assertTrue(self.transport.created.wait(1))
        [request] = dialog_requests(self.output)
        self.assertEqual(request["params"]["message"], "Why?\n\nBecause.")
        self.assertEqual(request["params"]["requestedSchema"]["required"], ["answer"])
        self.assertNotIn("choice", request["params"]["requestedSchema"]["properties"])

    def test_no_dialog_without_the_capability(self):
        self.init(elicitation=False)
        self.start()
        self.transport.answer.set()
        self.server.active[1][1].join(1)
        self.assertEqual(dialog_requests(self.output), [])
        self.assertEqual([m for m in lines(self.output) if "method" in m], [])

    def test_unknown_response_ids_are_ignored(self):
        self.server.handle({"jsonrpc": "2.0", "id": "q-99", "result": {"action": "accept"}})
        self.assertEqual(self.output.getvalue(), "")
```

(`setUp` passes `self.output` into `FakeTransport(self.output)`.)

- [ ] **Step 2: Run** — Expected: the four fail (`init` undefined / no dialog line / error line for the unknown id).

- [ ] **Step 3: Implement** the interfaces above. In `ask`, after `validate` and before the HA loop: `if self.elicitation and self.dialog_lock.acquire(blocking=False): dialog = self.open_dialog(question)`. Keep the rest of the loop as is for now (Task 3 wires the slot); in `finally`, `if dialog and not dialog.done: self.close_dialog(dialog, cancel=True)` so no dialog outlives its call.

- [ ] **Step 4: Run** — Expected: `OK` (14).

- [ ] **Step 5: Commit** — `git commit -am "questions: open a terminal dialog beside the inbox"`.

### Task 3: Terminal answers reach the inbox and the agent

**Files:**

- Modify: `files/scripts/lib/questions.py` (`ask`)
- Test: `files/scripts/lib/test-questions.py`

**Interfaces:**

- Consumes: `Dialog`, `open_dialog`, `close_dialog`, `ProtocolError`.
- Produces:
  - `Server.terminal_answer(dialog) -> str | None`: reads `dialog.response`; `accept` with `content.answer.strip()` → that text, else `content.choice` → that, else `""` (accept with nothing); `decline`/`cancel`/error → `None`.
  - `Server.record_terminal_answer(transport, auth, text, created: bool, cancel) -> dict`: finishes the HA create if needed (same three-failure rule), posts `{"op": "answer", "answer": text}`, retrying `ConnectionError` every `interval` for `answer_retry` seconds, and returns the result payload per the status table (below). Raises `ValueError` for `cancelled`/`expired`.
  - Result payloads: `delivered` → `{"status":"answered","answer":text,"question_id":id,"source":"terminal"}`; `answered` → `{"status":"answered","answer":<HA answer>,"question_id":id,"source":"inbox","discarded_terminal_answer":text}` and a `delivered` post; `ProtocolError` → post `cancel`, payload with `"source":"terminal","inbox":"unsupported"`; retries exhausted → `"source":"terminal","inbox":"unavailable"`, no `cancel`.
  - The HA path's payload gains `"source": "inbox"`.
  - Loop shape: each iteration first checks `dialog.event.is_set()`; empty accept re-opens the dialog (`close_dialog(dialog, cancel=False)` then `open_dialog`); then the HA post; the wait is `dialog.event.wait(interval)` while a dialog is open and not done, else `cancel.wait(interval)`.

- [ ] **Step 1: Write the failing tests**

```python
    def accept(self, content):
        [request] = dialog_requests(self.output)[-1:]
        self.reply(request["id"], {"action": "accept", "content": content})

    def result(self):
        [line] = [m for m in lines(self.output) if "result" in m and "method" not in m]
        return json.loads(line["result"]["content"][0]["text"])

    def test_terminal_answer_is_recorded_and_returned(self):
        self.init(); thread = self.start()
        self.accept({"choice": "Blue"}); thread.join(1)
        self.assertEqual(self.result() | {"question_id": None}, {"status": "answered", "answer": "Blue",
                                                                 "source": "terminal", "question_id": None})
        ops = [c["op"] for c in self.transport.calls]
        self.assertEqual(ops[0], "create"); self.assertEqual(ops[-1], "answer")
        self.assertNotIn("delivered", ops)
        self.assertEqual(self.transport.calls[-1]["answer"], "Blue")

    def test_terminal_answer_prefers_text_then_choice(self):
        for content, expected in (({"choice": "Red", "answer": " Purple "}, "Purple"),
                                  ({"choice": "Red", "answer": "  "}, "Red")):
            with self.subTest(content=content):
                self.setUp(); self.init(); thread = self.start()
                self.accept(content); thread.join(1)
                self.assertEqual(self.result()["answer"], expected)

    def test_empty_accept_reopens_the_dialog(self):
        self.init(); thread = self.start()
        self.accept({})
        for _ in range(100):
            if len(dialog_requests(self.output)) == 2: break
            time.sleep(0.01)
        self.assertEqual(len(dialog_requests(self.output)), 2)
        self.accept({"choice": "Red"}); thread.join(1)
        self.assertEqual(self.result()["answer"], "Red")

    def test_inbox_wins_a_tie(self):
        self.init(); thread = self.start()
        self.transport.answer_reply = {"status": "answered", "answer": "Red"}
        self.accept({"answer": "Blue"}); thread.join(1)
        result = self.result()
        self.assertEqual((result["answer"], result["source"], result["discarded_terminal_answer"]),
                         ("Red", "inbox", "Blue"))
        self.assertEqual(self.transport.calls[-1]["op"], "delivered")

    def test_cancelled_inbox_turns_a_terminal_answer_into_an_error(self):
        self.init(); thread = self.start()
        self.transport.answer_reply = {"status": "cancelled"}
        self.accept({"answer": "Blue"}); thread.join(1)
        self.assertTrue(lines(self.output)[-1]["result"]["isError"])

    def test_inbox_answer_carries_its_source(self):
        self.init(elicitation=False); thread = self.start()
        self.transport.answer.set(); thread.join(1)
        self.assertEqual(self.result()["source"], "inbox")
```

(add `import time` to the test imports; `self.result()` strips nothing: the `question_id` is a fresh UUID, hence the `| {"question_id": None}` comparison.)

- [ ] **Step 2: Run** — Expected: these six fail (no `answer` op posted, no `source`).

- [ ] **Step 3: Implement** `terminal_answer`, `record_terminal_answer`, the loop changes and the `source` field. Keep `ask`'s existing error handling: `record_terminal_answer` raising `ValueError`/`ConnectionError` lands in the existing `except` and the existing `finally` (which posts `cancel` only when not `finished`; set `finished = True` once a result was sent).

- [ ] **Step 4: Run** — Expected: `OK` (20).

- [ ] **Step 5: Lint and commit** — `pre-commit run ruff-check --files files/scripts/lib/questions.py files/scripts/lib/test-questions.py && git commit -am "questions: return and record terminal answers"`.

### Task 4: Phone first, declines, and cancellations close the dialog

**Files:**

- Modify: `files/scripts/lib/questions.py` (`ask`, `run`)
- Test: `files/scripts/lib/test-questions.py`

**Interfaces:**

- Consumes: `close_dialog(dialog, cancel=True)` emits `notifications/cancelled` only when the dialog has no response yet.
- Produces: `def cancellations(output)` test helper (messages with `method == "notifications/cancelled"`).

- [ ] **Step 1: Write the failing tests**

```python
    def test_inbox_answer_cancels_the_dialog_once(self):
        self.init(); thread = self.start()
        self.transport.answer.set(); thread.join(1)
        [cancelled] = cancellations(self.output)
        self.assertEqual(cancelled["params"]["requestId"], dialog_requests(self.output)[0]["id"])
        self.accept({"choice": "Red"})
        self.assertEqual(len([m for m in lines(self.output) if "result" in m and "method" not in m]), 1)
        self.assertEqual(self.result()["source"], "inbox")

    def test_decline_keeps_waiting_for_the_inbox(self):
        self.init(); thread = self.start()
        [request] = dialog_requests(self.output)
        self.reply(request["id"], {"action": "decline"})
        time.sleep(0.02)
        self.assertEqual([c["op"] for c in self.transport.calls if c["op"] not in {"create", "poll"}], [])
        self.transport.answer.set(); thread.join(1)
        self.assertEqual(cancellations(self.output), [])
        self.assertEqual(self.result()["source"], "inbox")

    def test_elicitation_error_is_a_decline(self):
        self.init(); thread = self.start()
        [request] = dialog_requests(self.output)
        self.server.handle({"jsonrpc": "2.0", "id": request["id"], "error": {"code": -32601, "message": "no"}})
        self.transport.answer.set(); thread.join(1)
        self.assertEqual(self.result()["source"], "inbox")

    def test_call_cancellation_closes_dialog(self):
        self.init(); thread = self.start()
        self.server.handle({"method": "notifications/cancelled", "params": {"requestId": 1}})
        thread.join(1)
        self.assertEqual(len(cancellations(self.output)), 1)
        self.assertEqual(self.transport.calls[-1]["op"], "cancel")
        self.assertEqual([m for m in lines(self.output) if "result" in m and "method" not in m], [])

    def test_eof_and_expiry_close_dialogs(self):
        self.init(); thread = self.start()
        self.server.run(io.StringIO()); thread.join(1)
        self.assertEqual(len(cancellations(self.output)), 1)
        self.setUp(); self.init(); self.server.timeout = 0.01
        self.server.ask(9, {"question": "Choose"}, threading.Event())
        self.assertEqual(len(cancellations(self.output)), 1)
        self.assertTrue(lines(self.output)[-1]["result"]["isError"])
```

- [ ] **Step 2: Run** — Expected: fail on the cancellation counts (none emitted, or emitted after a decline).

- [ ] **Step 3: Implement**: in the HA-answered branch call `close_dialog(dialog, cancel=True)` before sending the result; in the decline/error path call `close_dialog(dialog, cancel=False)` and set `dialog = None` plus a `declined = True` flag so no dialog reopens; the `finally` from Task 2 covers client cancel, expiry and `run()` EOF (which already sets every call's cancel event; the loop notices within one wait).

- [ ] **Step 4: Run** — Expected: `OK` (25).

- [ ] **Step 5: Commit** — `git commit -am "questions: first answer wins, the other side closes"`.

### Task 5: Inbox outages

**Files:**

- Modify: `files/scripts/lib/questions.py` (`ask`, `record_terminal_answer`)
- Test: `files/scripts/lib/test-questions.py`

- [ ] **Step 1: Write the failing tests**

```python
    def test_dialog_outlives_an_unreachable_inbox(self):
        self.init(); self.transport.down = True; self.server.interval = 0.001
        thread = self.start_without_create()      # like start(), waiting on the dialog request instead of created
        self.accept({"answer": "Blue"}); thread.join(2)
        result = self.result()
        self.assertEqual((result["answer"], result["source"], result["inbox"]), ("Blue", "terminal", "unavailable"))

    def test_declined_dialog_with_unreachable_inbox_is_the_usual_error(self):
        self.init(); self.transport.down = True
        thread = self.start_without_create()
        [request] = dialog_requests(self.output)
        self.reply(request["id"], {"action": "decline"}); thread.join(2)
        self.assertTrue(lines(self.output)[-1]["result"]["isError"])

    def test_rejected_answer_op_falls_back_to_cancel(self):
        self.init(); thread = self.start()
        self.transport.fail_answer = "protocol"
        self.accept({"answer": "Blue"}); thread.join(1)
        self.assertEqual(self.result()["inbox"], "unsupported")
        self.assertEqual(self.transport.calls[-1]["op"], "cancel")

    def test_answer_op_network_failure_retries_then_reports_unavailable(self):
        self.init(); self.server.answer_retry = 0.02; thread = self.start()
        self.transport.fail_answer = "network"
        self.accept({"answer": "Blue"}); thread.join(2)
        self.assertEqual(self.result()["inbox"], "unavailable")
        self.assertGreater(len([c for c in self.transport.calls if c["op"] == "answer"]), 1)
        self.assertNotIn("cancel", [c["op"] for c in self.transport.calls])
```

(`start_without_create(ident=1)` waits until `dialog_requests(self.output)` is non-empty instead of `transport.created`.)

- [ ] **Step 2: Run** — Expected: the first two fail with an error result instead of a terminal answer; the last two fail on `inbox`.

- [ ] **Step 3: Implement**: when the create loop raises `ConnectionError` and a dialog is open and not done, switch to a dialog-only wait (`dialog.event.wait(interval)` until `cancel` or deadline), then `terminal_answer`: text → payload with `"inbox": "unavailable"` (no HA posts); `None` → re-raise the `ConnectionError`. In `record_terminal_answer` implement the `ProtocolError` → `cancel` and retry-until-`answer_retry` branches, and the `created=False` case whose create attempts all fail → payload with `"inbox": "unavailable"` and no further posts; the `finally` must not post `cancel` after an `unavailable` result (`finished = True`).

- [ ] **Step 4: Run** — Expected: `OK` (29).

- [ ] **Step 5: Commit** — `git commit -am "questions: keep the dialog usable when the inbox is down"`.

### Task 6: One dialog at a time

**Files:**

- Modify: `files/scripts/lib/questions.py` (`ask` loop: acquire `dialog_lock` each iteration while no dialog has been shown and not declined)
- Test: `files/scripts/lib/test-questions.py`

- [ ] **Step 1: Write the failing test**

```python
    def test_dialogs_are_serialised(self):
        self.init(); first, second = self.start(1), self.start(2)
        time.sleep(0.02)
        self.assertEqual(len(dialog_requests(self.output)), 1)
        self.transport.answer.set()            # inbox answers both
        first.join(1); second.join(1)
        self.assertLessEqual(len(dialog_requests(self.output)), 2)
        results = [m for m in lines(self.output) if "result" in m and "method" not in m]
        self.assertEqual(sorted(m["id"] for m in results), [1, 2])

    def test_queued_dialog_opens_when_the_first_resolves(self):
        self.init(); first, second = self.start(1), self.start(2)
        self.accept({"choice": "Red"}); first.join(1)
        for _ in range(100):
            if len(dialog_requests(self.output)) == 2: break
            time.sleep(0.01)
        self.assertEqual(len(dialog_requests(self.output)), 2)
        self.accept({"choice": "Blue"}); second.join(1)
        answers = sorted(json.loads(m["result"]["content"][0]["text"])["answer"]
                         for m in lines(self.output) if "result" in m and "method" not in m)
        self.assertEqual(answers, ["Blue", "Red"])
```

- [ ] **Step 2: Run** — Expected: the second test fails (the queued call never opens a dialog) if Task 2 only tried once before the loop.

- [ ] **Step 3: Implement**: move the `dialog_lock.acquire(blocking=False)` attempt into the loop head (`if dialog is None and not declined and self.elicitation and ...`), so a queued call opens its dialog on its next iteration after the lock is released.

- [ ] **Step 4: Run** — Expected: `OK` (31).

- [ ] **Step 5: Commit** — `git commit -am "questions: one terminal dialog at a time"`.

### Task 7: Instructions and documentation

**Files:**

- Modify: `files/scripts/lib/questions.py:17-23` (`INSTRUCTIONS`), `files/config/question-instructions.md`, `remote-sessions.md:97-120`, `AGENTS.md:65-69`

- [ ] **Step 1: Update `INSTRUCTIONS`** (and `TOOL["description"]`, which reuses it): after "waits for their answer from the phone or inbox." add "In an interactive terminal the same question also opens as a dialog; the first answer, terminal or phone, wins." Keep the rest verbatim.

- [ ] **Step 2: Update `question-instructions.md`**: same sentence after the second sentence; keep the paragraph one paragraph.

- [ ] **Step 3: Update `remote-sessions.md`** paragraph starting "`flakelab.questions.enable = true;`": add that in Claude Code and Codex the question also opens as a native dialog (MCP elicitation), first answer wins, a phone answer closes the dialog and a terminal answer is recorded in the inbox (`source: terminal`) through hatyc's `answer` op; without elicitation (headless, other hosts) the inbox path alone is used; against a hatyc without the `answer` op the push is cancelled instead. Add to the rollout sentence that running sessions must reconnect MCP to get the dialog.

- [ ] **Step 4: Update `AGENTS.md`** bullet `questions.enable`: append "also opens a terminal dialog in clients with MCP elicitation; first answer wins".

- [ ] **Step 5: Verify** — `./files/scripts/test-questions` → `OK`; `pre-commit run --files files/scripts/lib/questions.py files/scripts/lib/test-questions.py files/config/question-instructions.md remote-sessions.md AGENTS.md` → all hooks pass.

- [ ] **Step 6: Commit** — `git commit -am "docs(questions): the terminal dialog"`.

### Task 8: Live check on this box

- [ ] **Step 1:** Run the server directly against both clients with the real inbox: start a Claude Code session and a Codex session (`flakelab sessions --start`), ask one question each; answer the first in the terminal (inbox shows `delivered` from the terminal, push gone), the second from the phone (dialog closes), decline a third in the terminal and answer it from the phone. Needs the hatyc MR deployed first; before that, the terminal answer path must show `inbox: unsupported` and a cancelled record.
- [ ] **Step 2:** Open the PR with the `cli-gitlab` skill's GitHub counterpart (`gh pr create`) from the branch; after merge, `flakelab update` on TycbookElite and gamertyc and reconnect MCP in running sessions.
