# Agent questions: terminal answers in the inbox (hatyc) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the agent-side question server record an answer the operator gave in the terminal, so the HA inbox stays the complete record and the phone push clears.

**Architecture:** One new webhook operation `answer` on the existing `flakelab_questions` inbox, authenticated with the call's capability token like `poll`. It stores the answer, marks the record `delivered` (the agent already has the answer) and `source: terminal`, and clears the push. Phone and panel answers get `source: inbox`. The panel shows the source.

**Tech Stack:** Home Assistant custom integration (Python, aiohttp webhook), plain JS panel, runtime tests in the HA container (`make test-runtime`).

**Spec:** `~/git/tyclab/flakelab/docs/superpowers/specs/2026-10-25-question-terminal-dialog-design.md`, section "HA side". The contract this repo must honour:

- Request: `{"id": <uuid>, "token": <capability>, "op": "answer", "answer": <text ≤ 12000>}` from the LAN webhook `<webhook_id>-questions`.
- Record `pending` → store `answer`, `status = "delivered"`, `source = "terminal"`, clear the phone notification, save. Reply `{"status": "delivered"}`.
- Any other status → no change; reply with the current status (and `answer` when it is `answered`), exactly as `poll` would.
- Wrong token or unknown id → 400 like every other op.
- A later phone or panel reply on that record is refused (status is not `pending`).
- Old agent servers never send `answer`; nothing else changes.

## Global Constraints

- No new secret, package or config key; the op rides on the existing webhook and `settings`.
- Text limits as the inbox has them: `answer` ≤ 12000 chars via `text(value, 12000)`.
- Records written before this change have no `source`; the panel must render them unchanged.
- `make test-runtime` (HA 2026.10.2 in docker, `--network none`) must stay green; `make lint` (pre-commit, ruff `E9,F`) must pass.

## Review Focus

- A phone reply and a terminal `answer` racing on the same record: exactly one wins and the loser gets a `ValueError`/current-status reply (Task 1 test `test_terminal_answer_and_phone_reply_cannot_both_win`).
- `answer` on an `answered` record (phone was first): reply carries the phone answer so the agent uses it (Task 1 test `test_terminal_answer_after_phone_reply_returns_phone_answer`).
- `answer` with an empty or over-long string: 400, record untouched (Task 1 test `test_terminal_answer_requires_text`).
- Restart between `answer` and the next snapshot: `source` and `delivered` survive (Task 1 test `test_terminal_answer_survives_restart`).
- Panel for an old record without `source`: no "undefined" text (Task 2, manual check in step 3).

---

### Task 1: `answer` operation in the inbox

**Files:**

- Modify: `custom_components/flakelab_questions/inbox.py:63-138` (`request`), `:140-151` (`answer`)
- Test: `tests/questions_runtime.py`

**Interfaces:**

- Consumes: `Inbox.request(body)` dispatch, `text()`, `self.notify(item, clear=True)`, `self.save()`.
- Produces: op `answer` as in the contract above; records gain `source` (`"terminal"` | `"inbox"`) whenever an answer is stored; `public()` keeps exposing it (it strips only `token_hash`, `nonce`, `lease`, `fingerprint`).

- [ ] **Step 1: Write the failing tests** in `tests/questions_runtime.py`, class `QuestionInboxTests`:

```python
    async def test_terminal_answer_is_recorded_as_delivered_and_clears_push(self):
        question = self.question()
        await self.post(question)
        response = await self.post({**question, "op": "answer", "answer": "Blue"})
        self.assertEqual((response.status, json.loads(response.text)), (200, {"status": "delivered"}))
        self.assertEqual(self.rt.calls[-1][2], {"message": "clear_notification",
                                                "data": {"tag": "flakelab-question-" + question["id"]}})
        [record] = await self.inbox.snapshot()
        self.assertEqual((record["answer"], record["status"], record["source"]), ("Blue", "delivered", "terminal"))
        with self.assertRaises(ValueError):
            await self.inbox.answer(question["id"], "Too late")

    async def test_terminal_answer_after_phone_reply_returns_phone_answer(self):
        question = self.question()
        await self.post(question)
        await self.inbox.answer(question["id"], "Red")
        response = await self.post({**question, "op": "answer", "answer": "Blue"})
        self.assertEqual(json.loads(response.text), {"status": "answered", "answer": "Red"})
        [record] = await self.inbox.snapshot()
        self.assertEqual((record["answer"], record["source"]), ("Red", "inbox"))

    async def test_terminal_answer_and_phone_reply_cannot_both_win(self):
        question = self.question()
        await self.post(question)
        results = await asyncio.gather(self.inbox.request({**question, "op": "answer", "answer": "Blue"}),
                                       self.inbox.answer(question["id"], "Red"), return_exceptions=True)
        [reply] = [r for r in results if isinstance(r, dict)]
        terminal_won = reply["status"] == "delivered"
        [record] = await self.inbox.snapshot()
        self.assertEqual((record["answer"], record["status"], record["source"]),
                         ("Blue", "delivered", "terminal") if terminal_won else ("Red", "answered", "inbox"))
        self.assertEqual(any(isinstance(r, ValueError) for r in results), terminal_won)

    async def test_terminal_answer_requires_text(self):
        question = self.question()
        await self.post(question)
        for bad in ("", "x" * 12001, 7):
            self.assertEqual((await self.post({**question, "op": "answer", "answer": bad})).status, 400)
        self.assertEqual(json.loads((await self.post({**question, "op": "poll"})).text), {"status": "pending"})

    async def test_terminal_answer_survives_restart(self):
        question = self.question()
        await self.post(question)
        await self.post({**question, "op": "answer", "answer": "Blue"})
        await self.rt.close()
        await self.runtime()
        await self.load_inbox()
        [record] = await self.rt.hass.data["flakelab_questions"].snapshot()
        self.assertEqual((record["status"], record["source"]), ("delivered", "terminal"))
```

- [ ] **Step 2: Run the suite to verify they fail**

Run: `make test-runtime`
Expected: the five new tests fail with 400 responses / `KeyError: 'source'`; all other tests pass.

- [ ] **Step 3: Implement the op** in `inbox.py`:
  - In `request()`, add an `elif operation == "answer":` branch between `cancel` and `delivered`: `if item["status"] == "pending": item.update(answer=text(body.get("answer"), 12000), status="delivered", source="terminal", updated=now); dirty = True; await self.notify(item, clear=True)`. Validate the text before mutating, so a bad value raises without a save. The reply falls through to the existing return (status, plus `answer` only when `answered`).
  - In `answer()` (phone/panel path), add `source="inbox"` to the `item.update(...)`.
  - The `asyncio.gather` race is serialised by `self.lock`; no further change.

- [ ] **Step 4: Run the suite to verify they pass**

Run: `make test-runtime`
Expected: `OK`, all tests including the five new ones.

- [ ] **Step 5: Lint and commit**

```bash
make lint
git add custom_components/flakelab_questions/inbox.py tests/questions_runtime.py
git commit -m "questions: record terminal answers through an answer op"
```

### Task 2: Panel shows where an answer came from; docs

**Files:**

- Modify: `custom_components/flakelab_questions/panel.js:98-104`
- Modify: `AGENT_QUESTIONS.md` (sections "Lifetime and privacy" and the flowchart)

**Interfaces:**

- Consumes: `record.source` from Task 1 (`"terminal"`, `"inbox"`, or absent).

- [ ] **Step 1: Render the source** in `panel.js` where `record.answer !== undefined`: change the heading text to `record.source === "terminal" ? "Your answer (terminal)" : "Your answer"`. No other wording changes; records without `source` render as before.

- [ ] **Step 2: Document** in `AGENT_QUESTIONS.md`:
  - flowchart: add `Agent -->|terminal dialog answer, op answer| Inbox` beside the existing poll edge;
  - "Lifetime and privacy": one paragraph: the agent server may post `op: "answer"` with the call's capability when the operator answered in the terminal dialog; the record becomes `delivered` with `source: terminal`, the push clears, and a later phone or inbox reply is refused; phone and inbox answers carry `source: inbox`.
  - "Validation": add "answer one question in the terminal dialog and confirm the inbox shows it as delivered from the terminal and the push is gone".

- [ ] **Step 3: Check the panel by hand** on the throwaway HA (`run-hatyc` skill): one record answered via `op: answer`, one via the panel, one old record restored without `source`; headings read "Your answer (terminal)", "Your answer", "Your answer".

- [ ] **Step 4: Lint and commit**

```bash
make lint
git add custom_components/flakelab_questions/panel.js AGENT_QUESTIONS.md
git commit -m "questions: show terminal answers in the inbox panel"
```
