# ask_question: terminal dialog beside the phone inbox

Date: 2026-10-25. Repos: `tyclab/flakelab` (`files/scripts/lib/questions.py`,
`test-questions`, `files/config/question-instructions.md`, `remote-sessions.md`,
`AGENTS.md`) and `tycstation/hatyc` (`custom_components/flakelab_questions/inbox.py`,
`tests/questions_runtime.py`, `AGENT_QUESTIONS.md`).

## Intent

Today an `ask_question` call is visible only in Home Assistant (push + Agent
questions inbox); the terminal shows a collapsed tool call. The operator wants the
question in both places and wants to answer from either. The MCP server that both
Claude Code and Codex already start shall open a native dialog in the terminal
through MCP elicitation while the question is posted to HA. The first answer wins;
the other side closes. HA stays the durable record, also for terminal answers.

Spike (2026-10-25, Claude Code 2.1.310, Codex 0.164.0) verified:

- both clients declare `capabilities.elicitation = {form: {}, url: {}}` at initialize
  (Claude Code offers protocol 2025-11-25, Codex 2025-06-18; both accept a server
  answering 2025-06-18);
- an enum property renders as a choice list, a two-property form (optional enum +
  optional free text) renders as a form (Claude Code) or a two-step wizard (Codex);
- accept returns `{"action":"accept","content":{...}}` with only the filled fields,
  decline returns `{"action":"decline"}`, Esc returns `{"action":"cancel"}`;
- a server-sent `notifications/cancelled` naming the elicitation request id closes
  the dialog in both clients at once and no late reply follows;
- Claude Code does not move a tool call to the background while its dialog is open
  (documented); Codex keeps the call in the foreground.

## Goals

- One `ask_question` call = one HA record + one terminal dialog, in Claude Code and
  Codex alike, with no new daemon, hook or client configuration.
- Answer from the terminal or from the phone/inbox; the loser closes within one
  poll interval (3 s) or immediately for the dialog.
- A terminal answer is recorded in the HA inbox with its answer text, so the inbox
  stays the complete history.
- Existing behaviour unchanged for clients without elicitation (headless
  `claude -p`, older or foreign MCP hosts): HA only, as today.
- Existing tests keep passing; new paths are covered by `test-questions` and
  hatyc's `questions_runtime.py`.

## Non-goals

- URL-mode elicitation, sampling, MCP tasks.
- Intercepting the clients' native permission dialogs (unchanged rule).
- Changing the phone/push UX or the panel beyond showing where an answer came from.
- Letting a dialog answer approve tools or bypass permissions.

## Anti-goals (failure even if it works)

- An answer returned twice, or a terminal answer and a phone answer both consumed.
- A fabricated answer on decline, Esc, timeout or cancel.
- A dialog left open after the phone answered, or a push left standing after the
  terminal answered.
- Terminal dialogs breaking the HA-only path when HA or the client lacks support.
- Secrets (webhook URL) leaking into dialog text, logs or errors.

## Constraints

- Server stays a dependency-free Python stdio JSON-RPC loop (no MCP SDK), single
  file, tested without a live inbox or client.
- Stay on protocol 2025-06-18 in the initialize reply.
- The HA inbox contract keeps its per-call capability token; the new operation
  uses the same token. Old flakelab servers never send it, so hatyc may ship first;
  a new flakelab against an old hatyc must degrade (see fallback).
- No change to the 25-minute answer window, 90-second lease, 50 active / 500
  retained limits.

## Design

### Capability detection

`initialize` stores `params.capabilities.elicitation` (truthy → dialogs on). The
reply is unchanged. Without the capability every call behaves exactly as today.

### Call flow (`Server.ask`)

1. Validate arguments.
2. If dialogs are on and no other dialog of this server is open, send
   `elicitation/create` before the first HA post, so the terminal never waits on
   HA. Server-side request ids come from their own namespace (string, e.g.
   `"q-<n>"`); `message` = question, then a blank line and the context when
   present; `requestedSchema`:
   - with options: `choice` (string, `enum` = options, `enumNames` = options,
     title "Choice") and `answer` (string, title "Or answer in your own words",
     `maxLength` 12000); neither required;
   - without options: `answer` (string, required, `maxLength` 12000).
     Dialogs are serialised: one open dialog per server process. Further calls queue
     in arrival order and open their dialog when the current one resolves (answer,
     decline, Esc, or cancel). A queued call that HA answers first never opens.
3. Post `create` to HA (as today, three failures before giving up), then wait on
   both sources: the HA poll loop as today (3 s), and the elicitation
   response delivered by `handle()` into the call's slot (an `Event` plus the
   response). The poll loop checks the slot each iteration, so a terminal answer
   is seen within one interval; the wait uses `Event.wait(interval)` on the slot's
   event instead of `cancel.wait`, so the terminal answer is seen at once and a
   client cancel still wakes the loop (both events are checked each iteration).
4. Outcomes:
   - **Terminal accept with content**: answer = `answer` if non-empty else
     `choice`. If the HA record does not exist yet (create still pending or
     failing), finish the create attempts first. Then post
     `{"op":"answer","answer":<text>}` with the call's id and token and act on the
     reply status:
     - `delivered`: return the terminal answer, `source: terminal`. No
       `delivered` op (the `answer` op records the answer as returned).
     - `answered`: the phone replied inside the last poll interval and HA
       recorded it first; the inbox is the arbiter. Return the HA answer with
       `source: inbox`, post `delivered`, and add
       `"discarded_terminal_answer": <text>` so nothing typed is lost silently.
     - `cancelled` / `expired`: the existing error result (the operator cancelled
       from the panel, or the window closed).
       If the `answer` post fails with an HTTP status (old hatyc answers 400 "Unknown
       operation"), post `cancel` so the push clears and return the terminal answer
       with `source: terminal`, `inbox: unsupported`. If it fails on the network,
       retry it every 3 s for up to 30 s, then return the terminal answer with
       `inbox: unavailable`; the 90 s lease expiry clears the push.
   - **Terminal accept with empty content**: send the same elicitation again (the
     operator pressed Accept without choosing). HA keeps waiting meanwhile.
   - **Terminal decline or cancel (Esc)**: dialog is gone, nothing is posted; the
     call keeps polling HA until answered, cancelled or expired, as today.
   - **Elicitation error reply** (client cannot serve it now): treat as decline.
   - **HA answered first**: send `notifications/cancelled` with `requestId` = the
     elicitation id and `reason` "answered from the inbox", then return the answer
     and post `delivered` as today. A terminal reply that still arrives after this
     is dropped (slot already closed).
   - **Client cancels the tool call**: as today (`cancel` to HA, no result) plus the
     same `notifications/cancelled` for the open elicitation.
   - **Expiry (25 min) or HA failure mid-call**: as today (error result, `cancel`),
     plus cancelling the open elicitation.
   - **HA unreachable at create** (3 failures): if a dialog is open, keep waiting
     on it alone and return its answer with `"inbox": "unavailable"`; if a terminal
     decline/cancel follows, return the existing error. Without a dialog, error as
     today.
5. Result text stays JSON: `{"status":"answered","answer":...,"question_id":...}`
   plus `"source": "terminal" | "inbox"` (additive).

`handle()` learns to route inbound messages that carry an `id` and `result`/`error`
but no `method` to the pending elicitation with that id; unknown ids are ignored.
`run()`'s EOF path cancels open elicitations' events too. Server-sent requests go
through the existing locked `send`. `Transport.post` distinguishes an HTTP status
reply (`ProtocolError`, a `ValueError` with a fixed message) from a network or
decoding failure (`ConnectionError`, as today); neither message carries the URL,
and `test_http_errors_never_reveal_secret_url` covers both.

### HA side (`inbox.py`)

New operation `answer`, authenticated like `poll` (id + token): if the record is
`pending`, set `answer` to `text(body["answer"], 12000)`, `status` → `delivered`,
`source` → `terminal`, `updated`; clear the phone notification (`notify(item,
clear=True)`); save. Any other status: no change (idempotent), reply with the
current status. The existing phone/panel reply path sets `source` → `inbox` when it
stores an answer (default for old records). The panel shows the source next to the
answer. `AGENT_QUESTIONS.md` documents the new op and the terminal path.

### Instructions and docs

- `INSTRUCTIONS` in `questions.py` and `files/config/question-instructions.md`:
  add that the question also opens as a dialog in the terminal and can be answered
  there or on the phone, whichever first; the rest of the text stays.
- `remote-sessions.md` and `AGENTS.md` (flakelab): one paragraph on the dialog,
  the first-answer-wins rule, the fallback without elicitation, and the hatyc
  dependency for the `answer` op.
- The Nix module needs no change: the same server binary, the same timeouts.

### Tests

flakelab `test-questions.py`, with a fake client that feeds `handle()` and reads the
output lines:

- initialize with `elicitation` capability → a call emits `elicitation/create`
  before the HA create, with the expected schema (options and no-options
  variants); without the capability no server-sent message appears and the result
  differs from today only by `source: inbox`.
- two calls at once → one dialog open, the second opens when the first resolves;
  a queued call answered by HA first never opens a dialog.
- terminal accept while HA already holds a phone answer (`answer` op replies
  `answered`) → HA answer returned with `source: inbox`,
  `discarded_terminal_answer` set, `delivered` posted, one result line.
- terminal accept (choice; text; both → text wins) → HA receives `answer` with the
  text, the tool result carries `source: terminal`, no `delivered` op.
- terminal accept with empty content → a second `elicitation/create`.
- terminal decline → no HA post and no `notifications/cancelled` (the dialog is
  already closed); the call still returns the later HA answer with `source: inbox`.
- HA answers first → `notifications/cancelled` emitted once; a late terminal
  accept is ignored; exactly one result line.
- tool-call cancellation and EOF → HA `cancel` and dialog cancel, no result.
- HA answers `answer` with an HTTP status → `cancel` follows, terminal answer
  returned with `inbox: unsupported`; a network failure → retries, then
  `inbox: unavailable` and no `cancel`.
- HA unreachable at create with dialogs on → dialog answer returned with
  `inbox: unavailable`; without dialogs → error as today.
- expiry with a dialog open → error result and dialog cancel.

hatyc `tests/questions_runtime.py`: `answer` op on a pending record stores the
answer, sets `delivered` + `source: terminal`, clears the notification; on a
non-pending record changes nothing; a wrong token is rejected; a phone reply after
a terminal answer is refused (status not pending); panel payload carries `source`.

### Rollout

1. hatyc MR: `answer` op + tests + doc; deploy via git-ha-ppens, restart HA.
2. flakelab PR: server + tests + instructions + docs; `flakelab update` on both boxes
   (TycbookElite, gamertyc); running sessions reconnect MCP (`/mcp`) or restart.
3. Check: one question per client answered in the terminal (inbox shows the answer
   with source terminal, push cleared), one answered from the phone (dialog closes),
   one declined in the terminal then answered from the phone.

## Decided by the operator

- Native terminal dialog, not text in the chat.
- Both clients, Claude Code and Codex.
- HA stays the record of every question and answer.

## Builder's calls (overridable)

- Decline/Esc in the terminal leaves the HA question open rather than cancelling it.
- Two optional fields when options exist (choice + free text) instead of one
  required enum, so a free-text answer works in the terminal as it does on the phone.
- Dialog proceeds when HA is unreachable at create (terminal-only fallback).
- `answer` from the terminal lands as status `delivered` (not `answered`), because
  the agent already has it; `source` distinguishes it in the panel.
- Fallback to `cancel` when hatyc does not know `answer` yet; network failures
  retry for 30 s instead and leave the push to the lease expiry.
- The dialog opens before the HA create, so the terminal never waits on HA; a
  terminal answer is returned once HA has recorded it or been given up on.
- Ties go to the inbox: a phone answer HA recorded first wins over a terminal
  answer typed in the same 3 s window; the typed text is returned alongside.
- One dialog at a time per server process; later calls queue.
- `source` is always present in the result.

## Left to the builder

- Exact slot/event structure inside `Server`, id format for server-sent requests,
  and the fake client helper in the tests.
- Panel wording for the source label.
