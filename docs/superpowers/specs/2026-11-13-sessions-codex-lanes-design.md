# `flakelab sessions`: Codex lanes with a model, an effort, a state and a close

Status: revision 2, 2026-11-13, after an independent review (its findings and what
became of each are listed at the end). Measured against codex-cli 0.169.0; source
references are to the tag `rust-v0.169.0` of `openai/codex`.

## Problem

An operator who runs several Codex sessions side by side (builders on one model, a
reviewer on a stronger one) starts each as a window of the `agents` tmux session.
Today that takes hand work that has gone wrong:

- `flakelab sessions --start codex <dir> -- -m <model> "<prompt>"` can pass a model
  and a first prompt, but Codex has no flag for the reasoning effort that keeps the
  session on the shared background server (`-c model_reasoning_effort=…` takes it
  off, F12). The effort was therefore set by typing `/model` key sequences into
  each window. One wrong key (Enter where `s` belonged) changed the default in
  `~/.codex/config.toml` for every later session.
- No command ends such a session. `/quit` in the window ends only the terminal
  side: the conversation stays on the shared server, and a command the turn had
  started (`sleep 90`) was still running after the quit.
- The table cannot tell which window holds which Codex session: the process in the
  window is a client of the shared server and holds no rollout, so its SESSION
  column is `-` and `--attach <id>` does not find it. Nothing says whether a
  session is working or done.

A script outside this repository solved the first two points by typing into the
Codex window and reading its screen. It works on 0.169.0, and in one evening three
defects came from reading a screen: the "Trust this folder?" question is drawn half
a second after the normal prompt (an Enter sent at the first prompt accepted it),
`/model` is refused while Codex starts up, and the script ended early when the
status line lacked one item. Every one of them was a guess about text and timing.

## What Codex offers (0.169.0)

"shared" is the operator's running background server, "private" a
`codex app-server` child on stdio. Every line was observed live unless it says
"source".

| #   | Fact                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              | How observed                                                                                                                                                                                                                                                                                                                                  |
| --- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| F1  | The shared server listens on `$CODEX_HOME/app-server-control/app-server-control.sock` and speaks WebSocket; each text message is one JSON object `{"method","id","params"}`, answered by `{"id","result"}` or `{"id","error"}`. A connection opens with `initialize` (client name and version; the answer's `userAgent` names the server's version) and the notification `initialized`. `codex app-server proxy` copies bytes and does not replace the WebSocket framing.                                                                                                                                                                                                                                                                                                                                                                                                                                         | handshake answered `101 Switching Protocols`; plain JSON lines through the proxy got no answer                                                                                                                                                                                                                                                |
| F2  | `codex app-server generate-json-schema --out <dir>` writes the protocol schema of the installed version. Without `--experimental` it holds `config/read`, `model/list`, `thread/start`, `thread/read`, `thread/turns/list`, `thread/loaded/list`, `thread/name/set`, `thread/archive`, `thread/delete`, `turn/start`, `turn/interrupt`; with it also `thread/backgroundTerminals/list` and `/clean`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              | generated both, compared the method lists                                                                                                                                                                                                                                                                                                     |
| F3  | `model/list` returns per model `id`, `model`, `displayName`, `isDefault`, `hidden`, `defaultReasoningEffort` and `supportedReasoningEfforts`, in pages (`nextCursor`). `config/read {cwd}` returns the effective `model` and `model_reasoning_effort` (either may be null) and the `projects` table with each folder's `trust_level`; it writes nothing.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          | shared; `config.toml` compared before and after                                                                                                                                                                                                                                                                                               |
| F4  | `thread/start {cwd, model, config: {model_reasoning_effort}}` creates a conversation and echoes that model and effort. An unknown model name is accepted without an error. A conversation with no turn has no rollout file: `codex resume <id>` on it ends at once and `thread/delete` answers "no rollout found".                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                | shared                                                                                                                                                                                                                                                                                                                                        |
| F5  | `turn/start {threadId, input: [{type: "text", text}], model, effort}` runs the turn with exactly that model and effort and keeps running after the client disconnects.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            | shared; `thread/read` polled from new connections; the rollout's turn record                                                                                                                                                                                                                                                                  |
| F6  | **Order matters.** A Codex window opened on a conversation before its first turn applies its own defaults to it: a conversation created with effort `ultra` ran its first turn with no effort set. When the first turn was started with explicit `model` and `effort` before the window opened, the window showed that model and effort, and two later prompts (one typed into the window, one sent with `codex queue`) ran on them too.                                                                                                                                                                                                                                                                                                                                                                                                                                                                          | shared; turn records of both orders                                                                                                                                                                                                                                                                                                           |
| F7  | `thread/read` gives `status.type`: `idle`, `active` (with `activeFlags` `waitingOnApproval` / `waitingOnUserInput`), `notLoaded`, `systemError`; and `model`, `reasoningEffort` (either may be null), `name`, `cwd`, `parentThreadId`. It answers for sessions started in a Codex window too. `thread/turns/list {threadId, limit: 1, sortDirection: "desc"}` gives the newest turn's `id` and `status` (`inProgress`, `completed`, …).                                                                                                                                                                                                                                                                                                                                                                                                                                                                           | shared                                                                                                                                                                                                                                                                                                                                        |
| F8  | `turn/interrupt {threadId, turnId}` from another connection stops the turn; it must name the active turn (source: `turn_processor.rs`). A command the turn started keeps running. `thread/backgroundTerminals/list` (paged) names it, `thread/backgroundTerminals/clean` ends it; both need `capabilities.experimentalApi` in `initialize`, and both answer "thread not found" for a conversation the server has not loaded.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      | shared; `sleep 300` counted before and after each call                                                                                                                                                                                                                                                                                        |
| F9  | A session at effort `ultra` starts helper agents as conversations of their own: `parentThreadId` names the parent, they stay loaded and were `idle` after the parent went idle.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   | shared, one session with three helpers                                                                                                                                                                                                                                                                                                        |
| F10 | `codex resume <id>` in a tmux window shows the conversation with its model and effort, live while a turn runs. A conversation started over the socket reads back `originator: "codex-tui"`, `source: "vscode"`, exactly like one started in a window.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             | shared                                                                                                                                                                                                                                                                                                                                        |
| F11 | **Trust.** `thread/start` with a `cwd` saves `[projects."<root>"] trust_level = "trusted"` without asking, and loads that folder's own settings in the same call, when all of these hold: the folder has no trust decision, its configuration is not projectless, and the effective permissions can write to it (source: `thread_processor.rs`, `requested_cwd.is_some() && config.active_project.trust_level.is_none() && !config.config_layer_stack.is_projectless() && effective_permissions_trust_project`). If saving fails it continues with the trust in memory. The decision is looked up for exactly two paths, the folder and its repository root, each by canonical and by given spelling (source: `get_active_project`, `resolve_root_git_project_for_trust`); for a git worktree the root is the main repository. A decision of `untrusted` is a decision. The Codex window asks before any of this. | source; and 14 throwaway folders on the shared server with `config.toml` compared around each call: entries appeared for an untrusted git repository (also from a subfolder, also below a trusted ancestor) and for a folder with `.codex`; none for a worktree or subfolder of a trusted repository, nor for folders without `.git`/`.codex` |
| F12 | `codex -m <model>` and a prompt argument work on the shared server. `-c model_reasoning_effort=…` works too when the window is pointed at the server with `--remote unix://<socket>`; without `--remote` any `-c` takes the session off the shared server (Codex's own startup warning says so; the review traced it to `daemon_startup.rs`). The session then runs in the server's folder, and nothing tells the caller its id.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  | shared                                                                                                                                                                                                                                                                                                                                        |
| F13 | `thread/archive` takes a conversation out of the default `thread/list`; `thread/delete` removes it and its rollout file. flakelab's own state sync pulls a deleted rollout back when it had already copied it to the state root.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  | shared; seven deleted test sessions were back within the hour                                                                                                                                                                                                                                                                                 |

## Goals

Each goal names the tests that pin it (suites under Tests).

- G1. `flakelab sessions --start codex <dir> --model M --effort E --prompt …`
  starts one session on the shared server whose first turn, and the turns after
  it, run on that model and effort; `config.toml` keeps its default model and
  effort. (U-start, Z-start, L1)
- G2. A wrong model or effort is refused before anything is created, with the list
  the server offers. (U-validate, L1)
- G3. flakelab starts a session only in a folder for which Codex already holds a
  trust decision, unless `--trust` is given. It reads the decision the way F11
  says Codex does. It cannot make Codex's own step atomic: if Codex still saves an
  entry, the start fails and names it. (U-trust, L2)
- G4. For the sessions the table already lists, and for the windows flakelab
  starts, the table and `--json` name the session id, its state, its model and
  effort. (U-state, Z-table)
- G5. `flakelab sessions --close <window>` removes a finished session's window and
  prints what brings it back; it refuses while the session, a helper agent of it
  or a command of it is running, unless `--force`, which stops those first.
  (U-stop, Z-close, L3)
- G6. A server that does not offer what a command needs is detected before the
  command changes anything; a failure after a change says what was done and what
  to run. (U-preflight, U-partial)
- G7. Without the new flags every existing command behaves as before, apart from
  two more columns in the table. (the existing cases of `test-claude-sessions`;
  only the cases that pin the header line and the column order change)

## Non-goals

- Claude Code windows. Claude takes model, effort and prompt on its own command
  line; state and close for Claude windows are separate work. The new flags and
  `--close` name Codex in their refusal for any other window.
- Listing sessions that are not running: the table stays what it is, the running
  sessions, because `--save`, `--resume`, `--open`, `--autosave` and `--recent`
  read the same rows.
- Usage limits and reset times; choosing models or accounts; waiting for a session
  to finish (a caller polls `--json`).
- Starting the shared server. If it does not answer, the error says what to run.
- Opening a view on a running Codex session that has no window (`--open` says
  "already running" today; unchanged).
- The dashboard's start form, and the standalone script that types into the window.
- Locking a conversation. Another Codex client can send it a prompt at any time;
  see "Closing" for what that means.

## Anti-goals

- A changed default in `config.toml`.
- A session off the shared server (the operator follows sessions from other
  devices through it).
- A trust entry the operator did not ask for (F11).
- Ending a window whose session, helper agents or commands are still running
  without being told to.
- Test sessions left in the operator's session list (F13).
- Account names, workspace ids or home paths in fixtures of this public repository.

## Approaches

**A. Type into the Codex window and read its screen.** What the outside script
does. Every step depends on the wording and timing of a screen (Problem); state
and close stay screen reads.

**B. Speak Codex's protocol to the shared server; the window is a view.** Model,
effort and prompt are data (F4, F5); the model list validates them (F3); state is
a field (F7); interrupt and clean are calls (F8); the id is known from the start,
so a window can be tied to its session. Costs: a WebSocket client in this
repository, the trust behaviour of F11, the order rule of F6, and a protocol whose
command-line entry is labelled experimental.

**C. Per-folder `.codex/config.toml` plus `codex -m` plus `codex queue`.** Puts a
file into every lane's folder, needs a saved trust entry per folder, and state and
close remain screen reads.

**D. Codex's own flags through `--remote` (F12).** `codex --remote unix://<socket>
-m M -c model_reasoning_effort=E "<prompt>"` starts with the right model and
effort, and Codex asks its trust question itself. It needs no code here beyond
building that command line. But the caller never learns the session's id, so the
table cannot tie the window to a session, and close has nothing exact to judge.

**Chosen: B** (my call; the operator handed over the how). Only B knows the id,
and state and close need it. D is the lightest way where starting is all that is
wanted. A is kept out; C's file and trust entry per folder are the complaint in
another form.

## Design

### Commands

```
flakelab sessions --start codex [dir] (--prompt TEXT | --prompt-file FILE)
                  [--model M] [--effort E] [--name NAME] [--trust] [--detach]
flakelab sessions --close [--force] [--archive] <window|session-id>...
```

- `--prompt`, `--prompt-file`, `--model`, `--effort`, `--name`, `--trust` are the
  lane flags. Any of them selects the protocol path, and that path needs a prompt
  (F4, F6: without a first turn there is nothing a window could open, and the
  effort would not hold). Usage errors (exit 2): a lane flag without a prompt;
  both prompt flags; a lane flag with `--start claude` or with `-- args`; a
  prompt file that is missing, unreadable, empty or not UTF-8; a `--name` that is
  no valid window name (`:`, `.`, space, over 40 characters). Without lane flags
  `--start` is unchanged.
- `--prompt TEXT` is on flakelab's own command line by the caller's choice;
  flakelab passes the text on by stdin only. `--prompt-file` keeps it off every
  command line. The text is sent byte for byte.
- `M` is matched without case against `id`, then `model`, then `displayName` of
  every page of `model/list` (hidden models included); two models matching one
  spelling is a refusal that lists both. The value sent is that entry's `model`.
  `E` must be one of the entry's `supportedReasoningEfforts`.
- Defaults: without `--model`, the `model` of `config/read`, else the entry with
  `isDefault`. Without `--effort`, `model_reasoning_effort` of `config/read` if
  the model offers it, else the model's `defaultReasoningEffort`. Both are always
  resolved to concrete values and sent explicitly (F6).
- `--name` names the window and the conversation (`thread/name/set`). A window of
  that name in `agents` is a refusal (exit 1). Without it the window is named as
  today and Codex names the conversation.
- Exit codes: 2 for a usage error (also an unknown model or effort), 1 for failed
  or refused work.

### Starting (protocol path)

One helper call does steps 1 to 6 on one connection.

1. Preflight, nothing changed yet: `initialize` (the server's version is kept for
   every later message), `config/read {cwd}`, all pages of `model/list`. Any
   missing method or field stops here (G6). Resolve model and effort (G2).
2. Trust (G3). Decision keys are the folder (canonical and as given) and its
   repository root: the parent of `git rev-parse --git-common-dir` when that
   ends in `/.git`, else `git rev-parse --show-toplevel`, else none. If
   `projects` holds no entry for any key, refuse: "Codex holds no trust decision
   for `<dir>`: open it once with `codex` and answer, or pass `--trust`". With
   `--trust` go on; Codex may then save an entry for the folder's root.
3. `thread/start {cwd, model, config: {model_reasoning_effort}}`. The answer must
   echo the model and effort.
4. `config/read` again. Without `--trust`, a `projects` key that is new and is the
   folder or one of its ancestors means Codex judged differently: the command
   stops with exit 1 and names the entry (the conversation has no turn and so
   leaves no file, F4). This is an alarm, not a rollback: the entry is saved and
   the folder's settings were loaded in step 3.
5. `thread/name/set` when `--name` was given.
6. `turn/start` with the prompt and explicit `model` and `effort`. From here the
   session is running; the helper prints its id, model, effort and turn id.
7. The window: `codex resume <id>` in the folder, through the existing
   `new_window`, with `CODEX_HOME` passed on when the caller has it set. The id
   is recorded on the window as the tmux option `@flakelab_session`.
8. After 3 s the window must still exist (a `codex resume` that cannot open its
   conversation ended, and tmux removed the window, within 1.0 s in three runs).
9. Attach or print the attach line, as `--start` does today.

What a failure leaves, and what the command prints:

| Fails                      | State                                                                       | Printed                                          |
| -------------------------- | --------------------------------------------------------------------------- | ------------------------------------------------ |
| steps 1, 2                 | nothing changed                                                             | the reason                                       |
| step 3                     | unknown: Codex may have created an empty conversation, which leaves no file | the reason                                       |
| step 4, 5                  | an empty conversation, no file; in step 4 a saved trust entry               | the entry (step 4); the reason                   |
| step 6, answer is an error | an empty conversation, no file                                              | the reason                                       |
| step 6, no answer in time  | the prompt may be running                                                   | the id and `codex resume <id>`; never sent again |
| steps 7, 8                 | the session runs without a window                                           | the id, `codex resume <id>`, exit 1              |

### Table and `--json`

- Only the `list` and `--json` modes ask the server; `--save`, `--resume`,
  `--open`, `--attach`, `--autosave` and `--recent` do not.
- The window's recorded id is read with one more `tmux list-panes` field and kept
  in its own map (window id to session id). The row records and their readers keep
  their shape: every reader takes `profile` as its last field and would swallow
  an appended one.
- A Codex row whose process holds no rollout shows the id recorded on its window.
  `--attach <id>` then finds the window. Saved sets are unchanged: a save is
  written from rows that carry their own id, and the server's row carries it.
- Asked for: the ids recorded on windows and the ids held by the shared server's
  process (the one whose command line is `codex app-server`). A session held by
  another Codex process (one started off the shared server) is not asked for: the
  shared server would call it `notLoaded` while it runs.
- One connection, each id once, 5 s for all of it (the dashboard gives the whole
  command 60 s and polls every 15 s). What did not arrive in time is unknown.
- Table: `STATE` and `MODEL` after `HOST`; `MODEL` is `<model> <effort>`. `--json`:
  `state`, `model`, `effort`, each null when unknown. Existing keys and types stay.
- States: `idle`, `working` (`active`, no flag), `approval`, `question`
  (`approval` wins when both flags are set), `unloaded`, `error`. In the table
  `-` means not asked, `?` asked and not answered; one note on stderr, exit 0.
- `--open` records the id on every Codex window it creates, so a session brought
  back after a restart can be found and closed like one just started.

### Closing

A window is a view; the conversation lives on the server. `--close` removes the
view and, with `--force`, stops the conversation's work first. It does not lock
the conversation: another client can send it a prompt between the last check and
the removal. The last check is made immediately before the window is removed, and
the output says what was seen.

Targets, each resolved once to window ids and deduplicated: a window of `agents`
by name or `@id`, or a session id, which selects every window that records it. A
name that matches several windows is refused with their ids. A target that
selects no window is an error (exit 2).

A window is closed only if it still is what flakelab started: it records a
session, has exactly one pane, and that pane's start command is `codex resume`
with the recorded id. Otherwise it is refused. If the operator has switched the
view to another conversation inside Codex, flakelab cannot see that; that other
conversation is not touched and stays in the table through the server's row.

For one session:

1. Read `thread/read`; for `notLoaded` nothing runs on this server and steps 2
   and 3 are skipped (F8).
2. Helper agents: every loaded conversation whose chain of `parentThreadId`
   leads to this one (`thread/loaded/list`, one `thread/read` each).
3. Background terminals of the session and of each helper, all pages.
4. Finished means: the session `idle` or `notLoaded`, every helper `idle`, no
   terminal. Then, after one more `thread/read` that still says so, remove the
   windows and print, on stdout, `cd <dir> && codex resume <id>`.
5. Not finished: refuse with the reason (working, waits for an approval, waits
   for an answer, helper agent `<name>` working, runs `<command>`, error) and
   exit 1. A terminal list that cannot be read is a reason.
6. `--force`: for the session and each working helper, read the newest turn
   (`thread/turns/list`), and if it is in progress `turn/interrupt` it; a refusal
   because the turn changed is answered by reading again. Then
   `thread/backgroundTerminals/clean` for each, then steps 1 to 4. The whole stop
   has 30 s (an interrupt and a clean each took under 3 s when measured); on
   expiry exit 1, windows untouched, with what is still running. A session in
   `error` is not interrupted; its terminals are cleaned and its windows removed.
   `--force` stops the conversation for every client that views it.
7. `--archive`: after the windows are gone, `thread/archive`; the printed line is
   then `codex unarchive <id>` and the resume line. If archiving fails, exit 1
   and say that the window is gone and the session is not archived.

All targets are processed; exit 1 if any was refused or failed.

### The helper

`files/scripts/lib/codex_threads.py`, python3 standard library. `claude-sessions`
calls it; nothing else does. `FLAKELAB_CODEX_THREADS` names it (a test seam, like
the other suites' seams); `CODEX_HOME` names the socket's home.

```
codex_threads.py start --cwd DIR [--model M] [--effort E] [--name N] [--trust]   # prompt on stdin
codex_threads.py state [--deadline SECONDS] ID...
codex_threads.py close-check ID            # steps 1 to 4 above, read only
codex_threads.py stop ID                   # step 6
codex_threads.py archive ID
```

Stdout is one JSON document; stderr one `Error: …` line on failure, with the
server's version when a connection existed.

```
start        {"session","model","effort","turn","server"}
state        [{"session","state","model","effort","name"}]     # state null: no answer
close-check  {"session","finished": bool,"state","reasons":[…],"cwd"}
stop         {"session","interrupted":[ids],"cleaned":[ids]}
archive      {"session","archived": true}
```

The client: a WebSocket client over the unix socket and a request layer.

- Handshake with a fresh key; the server's accept value is computed and checked.
- Client frames are masked text frames. Server frames: text and continuation
  frames are joined, a ping is answered, a close ends the connection, a message
  above 16 MiB (the limit the server announces) is refused.
- A message with a `method` is a notification or a request from the server, even
  when it carries an `id`; only a message without `method` whose `id` matches is
  an answer. The client answers no server request (it approves nothing) and
  disconnects after its last call.
- 5 s to connect, 30 s per call unless a command sets a deadline for the whole of
  its work (`state`, `stop`). The slowest measured call took under 2 s.
- Every answer is checked for the fields the command reads; a missing field or an
  unknown status word names the method, the field and the server's version.

A library would do the framing as well. It would also put a dependency on the
wrapper and on both suites, which today run on whatever `python3` is on the PATH;
the frame handling here is about a hundred lines and is tested against recorded
bytes and a live server. (My call.)

### Packaging and documents

- `nix/scripts.nix`: `pkgs.python3` on the `claude-sessions` wrapper's PATH.
- `nix/checks.nix`: `codex-threads = suiteCheckWith [ pkgs.python3 ] "codex-threads"`,
  and `claude-sessions` likewise (one of its cases runs the real helper).
  `Makefile`: the new suite in the `test` list.
- `docs/agents/cli-development.md` (the `sessions` entry), README's sessions
  section, the usage text, CHANGELOG.

## Tests

**U: `test-codex-threads`** (python unittest, `lib/test-codex-threads.py`). The
helper runs as a subprocess against a WebSocket server inside the test. That
server keeps state (conversations, turns, terminals, the `projects` table),
checks every request's parameter values against what the case expects, computes
the handshake from the client's key, and can answer late, in fragments, with
notifications and server requests in between, with an error, or not at all. Its
answers are shaped from exchanges recorded on 0.169.0
(`lib/testdata/codex-app-server/0.169.0/`, sanitised), so a field the real server
does not send is not in them.

- U-frames: recorded bytes (the handshake answer, a short message, one above
  125 bytes, one above 64 KiB, one in two fragments with a ping between); a wrong
  accept value, a truncated frame, a close, a message above the limit.
- U-preflight: a server without `model/list`, without `thread/turns/list`, or
  whose `config/read` lacks `projects`: exit 1 before any `thread/start`.
- U-validate: unknown model, effort the model lacks, a spelling two models share:
  exit 2, the offered list, no `thread/start`. Defaults: null config model, null
  config effort, a config effort the chosen model lacks, a model on the second
  page.
- U-start: the calls in order; `thread/start` and `turn/start` carry the resolved
  model and effort; the prompt arrives byte for byte, also with newlines and
  non-ASCII text.
- U-trust: no entry, entry for the folder, entry for the repository root, a
  worktree of a trusted repository, an entry `untrusted`, a symlinked spelling:
  the verdict for each; `--trust`; the server saving an entry anyway (step 4).
- U-partial: an error or no answer after each of steps 3 to 6: the exit code and
  the printed lines of the table above; `turn/start` is never sent twice.
- U-state: each status to its word, both flags, an unknown id, the deadline with a
  server that answers the first ids and then stalls.
- U-stop: a session with a helper agent and a terminal: interrupt, clean, empty
  lists; a turn that changes between read and interrupt; a terminal list in two
  pages; a terminal that does not go away: exit 1 at the deadline; `error`;
  `notLoaded` asks for no terminals.

**Z: `test-claude-sessions`** (existing zsh suite, new cases). Most cases replace
the helper by a stand-in that logs its arguments and prints the documents above.
One case runs the real helper against the U suite's server, started by a small
script both suites share, so the two sides are tested against each other and not
against two copies of a sample. The tmux stand-in fails on a command or a format
string it does not know.

- Z-start: every usage error of "Commands"; the window command is
  `codex resume <id>`; the id is recorded; `CODEX_HOME` is passed on; a window
  that is gone after 3 s gives exit 1 and the resume line; the prompt reaches the
  helper on stdin.
- Z-table: a client row takes the id of its window; `STATE` and `MODEL`; the
  `--json` keys; server down gives `?` and exit 0; `--save`, `--autosave`,
  `--resume`, `--recent` and `--attach` run without asking the helper; `--open`
  records the id on its new Codex windows.
- Z-close: finished closes and prints the resume line; not finished is refused;
  `--force` stops first; `--archive` and its failure; a window with two panes, a
  window whose command is another session's, a window without a session: refused;
  a session id with two windows closes both; a name on two windows is refused;
  several targets with one refused: exit 1 and the others closed.

**L: live checks** (`FLAKELAB_CODEX_LIVE=1 files/scripts/test-codex-threads`;
never part of `make test` or the flake check; run by the builder on a box with
Codex and again after a Codex update). Each check works in folders of its own,
records the ids it creates, and removes them in a step that runs whatever
happened before: `thread/delete`, then the copy under the state root if there is
one (F13). A cleanup that fails is reported with what is left. Trust is compared
per folder key, not by comparing the whole of `config.toml`, which other sessions
may change meanwhile.

- L1: start on a cheap model at its lowest effort with a one-word prompt, through
  `flakelab sessions --start`. The window exists; `thread/read` after the window
  attached names the model and effort; the rollout's turn record names them (the
  only place the test reads a rollout); the default in `config.toml` is unchanged;
  an unknown model and an unknown effort are refused.
- L2: a fresh folder with `.git`: refused without `--trust`, no entry for it
  afterwards.
- L3: a prompt that runs `sleep`: the terminal list names the command (that, not
  a process search, proves it started); close refuses; `--force` ends the turn
  and the terminal list is empty; the window is gone.

## What the review changed

Reviewed 2026-11-13 by an independent model session with three helper sessions,
read-only, without access to the shared server. I checked its claims against the
0.169.0 source and on the shared server before changing anything.

| Finding                                                             | Outcome                                                                                                                                                                                                                                            |
| ------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1. The trust check repeats a guessed rule and checks after the fact | Confirmed in source. F11 and step 2 now follow Codex's lookup (folder and repository root, any decision). G3 says what flakelab cannot do. Folders without a decision need `--trust` even where Codex would save nothing.                          |
| 2. A recorded id is not enough authority to end a window            | The window must have one pane and the command flakelab started. Several windows on one session, repeated targets and ambiguous names are defined. A view switched inside Codex cannot be detected; the text says so.                               |
| 3. Closing is a sequence of observations                            | Turn ids, pages, a turn that changes, helper agents (F9), `notLoaded` (measured, F8), `error`, one deadline, and the missing lock are in "Closing". Queued messages and goals are not handled: the last check before removal reports what it sees. |
| 4. "Changes nothing" cannot be kept after a change                  | G6 reworded; the failure table says what each step leaves.                                                                                                                                                                                         |
| 5. "Every session the server knows" has no source of rows           | G4 reworded to the rows the table has; the new values are kept out of the row records.                                                                                                                                                             |
| 6. A created window is not a working view                           | `CODEX_HOME` is passed on; the window must survive 3 s; start and first turn are one call on one connection.                                                                                                                                       |
| 7. Recovered windows lose their id                                  | `--open` records it. A view on a running session without a window stays out (Non-goals).                                                                                                                                                           |
| 8. Model and default rules were loose                               | Stated under "Commands".                                                                                                                                                                                                                           |
| 9. Per-call limits could starve other readers                       | Only `list` and `--json` ask; 5 s for all of it; one deadline for a stop.                                                                                                                                                                          |
| 10. The comparison left out Codex's own flags                       | Problem and F12 corrected; approach D added and measured.                                                                                                                                                                                          |
| 11. The tests could pass while the behaviour is wrong               | The test server keeps state and checks values; one zsh case runs the real helper; the live checks record and remove their own sessions.                                                                                                            |
| 12. Contracts between shell and helper were missing                 | The helper's documents and the usage errors are listed.                                                                                                                                                                                            |

Found by running the first draft's own start sequence for that review, not by the
review: F6 (the reviewer's session ran its first minute on the default effort and
was restarted) and F13.

Two calls the review left to the operator, made here and easy to change: the
table stays the list of running sessions (Non-goals), and `--close --force` stops
a conversation for every window that shows it.
