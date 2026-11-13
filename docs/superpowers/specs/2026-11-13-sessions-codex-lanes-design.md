# `flakelab sessions`: Codex lanes with a model, an effort, a state and a close

Status: draft for review, 2026-11-13. Measured against codex-cli 0.169.0.

## Problem

An operator who runs several Codex sessions side by side (builders on one model, a
reviewer on a stronger one) starts each as a window of the `agents` tmux session.
Today that takes hand work that has gone wrong:

- `flakelab sessions --start codex <dir>` cannot say which model, which reasoning
  effort or which first prompt the session gets. The model and effort were set by
  typing `/model` key sequences into each window. One wrong key (Enter where `s`
  belonged) changed the default in `~/.codex/config.toml` for every later session.
- No command ends such a session. `/quit` in the window ends only the terminal
  side: the conversation stays on Codex's shared background server, and a command
  the turn had started (`sleep 90`) was still running after the quit.
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

## What Codex offers (measured on 0.169.0)

Each line was observed on a live server; "shared" means the operator's running
background server, "private" a `codex app-server` child on stdio.

| #   | Fact                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  | How observed                                                                      |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| F1  | The shared server listens on `$CODEX_HOME/app-server-control/app-server-control.sock` (a link into `/tmp/codex-daemon-<uid>/`) and speaks WebSocket; each text message is one JSON object `{"method","id","params"}`, answered by `{"id","result"}` or `{"id","error"}`. The session opens with `initialize` (client name and version) and the notification `initialized`.                                                                                                                                                                                                                                                                                                            | handshake answered `101 Switching Protocols`; calls below                         |
| F2  | `codex app-server generate-json-schema --out <dir>` writes the protocol schema of the installed version. Without `--experimental` it holds, among others, `config/read`, `model/list`, `thread/start`, `thread/read`, `thread/name/set`, `thread/archive`, `thread/delete`, `turn/start`, `turn/interrupt`; with it also `thread/backgroundTerminals/list` and `/clean`.                                                                                                                                                                                                                                                                                                              | generated both, compared the method lists                                         |
| F3  | `model/list` returns per model `id`, `displayName` and `supportedReasoningEfforts` (one model lacks `ultra`). `config/read` returns the effective default `model` and `model_reasoning_effort`, and the `projects` table with each folder's `trust_level`.                                                                                                                                                                                                                                                                                                                                                                                                                            | shared                                                                            |
| F4  | `thread/start {cwd, model, config: {model_reasoning_effort}}` creates a conversation with that model and effort. An unknown model name is accepted without an error.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  | shared; response fields `model`, `reasoningEffort`                                |
| F5  | `turn/start {threadId, input: [{type: "text", text}]}` runs with the thread's model and effort and keeps running after the client disconnects.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        | shared; polled `thread/read` from new connections: `active` for 24 s, then `idle` |
| F6  | `thread/read` gives `status.type`: `idle`, `active` (with `activeFlags` `waitingOnApproval` / `waitingOnUserInput`), `notLoaded`, `systemError`; and `model`, `reasoningEffort`, `name`, `cwd`. It answers for sessions started in a Codex window too.                                                                                                                                                                                                                                                                                                                                                                                                                                | shared                                                                            |
| F7  | `turn/interrupt {threadId, turnId}` from another connection stops the turn. A command the turn started keeps running. `thread/backgroundTerminals/list` names it, `thread/backgroundTerminals/clean` ends it; both need `capabilities.experimentalApi` in `initialize`.                                                                                                                                                                                                                                                                                                                                                                                                               | shared; `sleep 300` counted with `pgrep` before and after each call               |
| F8  | `codex resume <id>` in a tmux window shows the conversation with its model and effort in the status line, live while a turn runs; `/status` there reads "Server: Local background server".                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            | shared                                                                            |
| F9  | A conversation started over the socket reads back `originator: "codex-tui"`, `source: "vscode"`, exactly like one started in a Codex window.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          | shared, both kinds read                                                           |
| F10 | `thread/archive` takes a conversation out of the default `thread/list`; `thread/delete` removes it and its rollout file.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              | shared                                                                            |
| F11 | **Trust.** `thread/start` in a folder Codex has not been told to trust saves `[projects."<root>"] trust_level = "trusted"` to `config.toml` without asking, and loads that folder's own settings in the same call. The Codex window asks first. A folder needs trust when it, or an ancestor, holds `.git` or `.codex`; the entry is written for that ancestor (for a git worktree: nothing is written when the main repository is trusted). A trusted ancestor does not cover a nested folder with its own `.git` or `.codex`. A folder with no such ancestor gets no entry. `.agents`, `.hg`, `.jj`, `.sl`, `.claude` and `AGENTS.md` are no markers. `config/read` writes nothing. | shared, 14 throwaway folders, `config.toml` compared before and after each call   |
| F12 | `codex -m <model>` sets the model and stays on the shared server; there is no flag for the effort. A `.codex/config.toml` in the folder sets both, once the folder is trusted. `codex queue --thread <id> --message <text>` delivers a prompt to an open session.                                                                                                                                                                                                                                                                                                                                                                                                                     | shared                                                                            |

## Goals

Each goal names the test that pins it (suites under Tests below).

- G1. `flakelab sessions --start codex <dir> --model M --effort E --prompt …`
  starts one session on the shared server with that model and effort for that
  session only, sends the prompt, and opens its window. `config.toml` keeps its
  default model and effort. (U-start, Z-start, L1)
- G2. A wrong model or effort is refused before anything is created, with the list
  the server offers. (U-validate, L1)
- G3. Starting never trusts a folder on its own. (U-trust, L2)
- G4. The table and `--json` name the session, its state, its model and effort for
  every Codex session the server knows, and tie a window to its session.
  (U-state, Z-table)
- G5. `flakelab sessions --close <window>` ends a finished session's window and
  prints what brings it back; it refuses one that is working or has a command
  running unless `--force`, which stops both first. (U-stop, Z-close, L3)
- G6. A Codex version whose protocol differs fails with a named reason and
  changes nothing. (U-drift)
- G7. Without the new flags every existing command behaves as before.
  (the existing cases of `test-claude-sessions`, unchanged)

## Non-goals

- Claude Code windows. Claude takes model, effort and prompt on its own command
  line (`--start claude <dir> -- --model … "prompt"` works today); state and close
  for Claude windows are separate work. The new flags and `--close` name Codex in
  their refusal for any other window.
- Usage limits and reset times (F3's neighbour `account/rateLimits/read` exists).
- Choosing models or accounts, or waiting for a session to finish: a caller polls
  `--json`.
- Starting the shared server. If it does not answer, the error says what to run.
- The dashboard's start form.
- The standalone script that types into the window: it stays outside the repository.

## Anti-goals

- A changed default in `config.toml`.
- A session off the shared server (the operator follows sessions from other
  devices through it).
- A trust entry the operator did not ask for (F11).
- Closing a working session without being told to.
- Test sessions left in the operator's session list.
- Account names, workspace ids or home paths in fixtures of this public repository.

## Approaches

**A. Type into the Codex window and read its screen.** What the outside script
does. Works without knowing the session id. Every step depends on the wording and
timing of a screen; three defects in one evening (Problem). State and close stay
screen reads.

**B. Speak Codex's own protocol to the shared server; the window is a view.**
`thread/start` and `turn/start` carry model, effort and prompt as data (F4, F5);
the model list validates them (F3); state is a field (F6); interrupt and clean are
calls (F7); the window runs `codex resume <id>` (F8). Costs: a WebSocket client in
this repository, the trust behaviour of F11, and a protocol whose command-line
entry is still labelled experimental.

**C. Per-folder `.codex/config.toml` plus `codex -m` plus `codex queue` (F12).**
No protocol client. Puts a file into every lane's folder, needs a saved trust
entry per folder, and state and close remain screen reads.

**Chosen: B** (my call; the operator handed over the how). It replaces guessed
text and timing with fields the server answers, it is the interface Codex's own
clients use (F9), and it is the only one of the three that knows a session's state
and id. A is kept out; C's file and trust entry per folder are what the operator
complained about in another form.

## Design

### Commands

```
flakelab sessions --start codex [dir] [--model M] [--effort E]
                  [--prompt TEXT | --prompt-file FILE] [--name NAME] [--trust] [--detach]
flakelab sessions --close [--force] [--archive] <window|session-id>...
```

- `--model`, `--effort`, `--prompt`, `--prompt-file`, `--name` and `--trust` are
  the lane flags. Any of them selects the protocol path below. With `--start
claude`, or together with `-- args`, they are a usage error (exit 2). Without
  them `--start` is unchanged (G7).
- `M` is a model id or display name from `model/list`, compared without case
  (`gpt-6.1-sol`, `GPT-6.1-Sol`). `E` is one of that model's effort ids. `--effort`
  alone applies to the effective default model from `config/read`.
- `--name` names the window and the conversation (`thread/name/set`), so the lane
  carries one name in tmux and in every Codex client. It must be a valid window
  name (no `:`, `.` or space, at most 40 characters) and not in use in `agents`.
  Without it the window is named as today (`codex-<dir>`), and Codex names the
  conversation itself.
- Exit codes follow the repository's rule: 2 for a usage error (unknown flag,
  model or effort), 1 for failed or refused work.

### Starting (protocol path)

1. `config/read` for the folder, `model/list`: resolve model and effort; refuse
   what the list does not offer and print the list (G2).
2. Trust (G3): find the nearest of the folder and its ancestors that holds `.git`
   or `.codex` (the folder that holds Codex's own home directory does not count).
   If there is one and neither it nor, for a git worktree, the main repository's
   folder is `trusted` in `projects`, refuse: "Codex has not been told to trust
   `<root>`: open it once with `codex` and answer, or pass `--trust`". With
   `--trust` go on; Codex then saves the entry itself.
3. `thread/start {cwd, model, config: {model_reasoning_effort}}`. The answer must
   name the requested model and effort.
4. `config/read` again: `projects` must be what it was, unless `--trust` was
   given. A new entry means step 2 judged differently from Codex: delete the
   conversation, exit 1, name the entry. (Step 2 is built to refuse too often
   rather than too rarely; this check is the proof on every start.)
5. `thread/name/set` when `--name` was given.
6. The window: `codex resume <id>` in the folder, created by the existing
   `new_window`; the tmux window option `@flakelab_session` records the id. If
   the window cannot be created, the empty conversation is deleted.
7. With a prompt: `turn/start`. The text goes to the helper on stdin, never on a
   command line. If this fails, the window stays and the command exits 1.
8. Attach or print the attach line, as `--start` does today.

### Table and `--json`

- `load_panes` asks tmux for `#{@flakelab_session}` as one more field. A Codex
  row whose process holds no rollout takes the id recorded on its window, so
  SESSION is filled, `--attach <id>` finds the window, and `--save` records it.
- For every Codex session id in the table one `thread/read` (all on one
  connection): the table gains `STATE` and `MODEL` after `HOST`; `--json` gains
  `state`, `model`, `effort` (null when unknown).
- States: `idle`, `working` (`active`, no flag), `approval`, `question`,
  `unloaded` (`notLoaded`: nothing running, the server has not loaded it),
  `error`. `-` for a row without a session, `?` when the server did not answer;
  the table itself never fails for that, a note goes to stderr once.

### Closing

Each target is a window of `agents` by name or `@id`, or a session id. A target
that names no window but is a session id the server knows is handled without the
window step.

1. A window without a recorded Codex session is refused: the tool does not end
   what it cannot judge.
2. `thread/read` and `thread/backgroundTerminals/list`.
3. `idle` or `unloaded`, no background terminal: kill the window, print the resume
   line in `--resume`'s shape (`cd <dir> && codex resume <id>`) on stdout.
4. Anything else is refused with the reason (working, waits for an approval,
   waits for an answer, runs `<command>`, error) and exit 1. If the background
   list cannot be read, that is a reason too.
5. `--force`: `turn/interrupt` for each turn in progress, wait until the status is
   no longer `active`, `thread/backgroundTerminals/clean`, read the list until it
   is empty, then step 3. The waits end after 30 s (an interrupt took under 3 s
   when measured) with exit 1 and the window untouched.
6. `--archive`: after step 3, `thread/archive`; the printed line is then
   `codex unarchive <id>` followed by the resume line.

All targets are processed; the exit code is 1 if any was refused or failed.

### The helper

`files/scripts/lib/codex_threads.py`, python3 standard library only, like
`lib/mcp.py` and `lib/web.py`. `claude-sessions` calls it; nothing else does.

```
codex_threads.py start --cwd DIR [--model M] [--effort E] [--name N] [--trust]
codex_threads.py turn --session ID            # prompt on stdin
codex_threads.py state [--background] ID...
codex_threads.py stop ID
codex_threads.py archive ID
codex_threads.py delete ID
```

Each prints one JSON document on stdout and one `Error: …` line on stderr when it
fails; exit codes as above. `FLAKELAB_CODEX_THREADS` names the helper (a test
seam, like the other suites' seams), `CODEX_HOME` the socket's home.

Inside: a WebSocket client over the unix socket (handshake, masked text frames,
continuation frames, ping answered, close), a request/response layer that keeps
notifications apart, and one function per command. Limits: 5 s to connect, 30 s
per call (the slowest measured call, `model/list`, took under 2 s).

Every answer is checked for the fields the command reads. A missing field, an
unknown status or an error for a method names the method, the field and
`codex --version`, exits 1 and leaves windows and conversations as they were
(G6).

### Packaging and documents

- `nix/scripts.nix`: `pkgs.python3` on the `claude-sessions` wrapper's PATH.
- `Makefile` and `nix/checks.nix`: the new suite `test-codex-threads`.
- `docs/agents/cli-development.md` (the `sessions` entry), README's sessions
  section, the usage text, CHANGELOG.

## Tests

**U: `test-codex-threads`** (python unittest, `lib/test-codex-threads.py`). The
helper runs against a WebSocket server in the test process that replays exchanges
recorded from 0.169.0 (`lib/testdata/codex-app-server/0.169.0/`, sanitised). The
server refuses any request that differs from the recorded one in method or
parameter names, so the test fails when the helper asks something the real server
was never asked. Frame handling is tested on recorded bytes: the handshake answer,
a short message, one above 125 bytes, one above 64 KiB, one in two fragments.

- U-start: the calls of "Starting" in order, with model and effort in
  `thread/start`; no call writes config.
- U-validate: unknown model, effort the model lacks: exit 2, the offered list,
  no `thread/start`.
- U-trust: the folder cases of F11 as a table on temporary folders, each with the
  expected verdict; the changed-`projects` answer after `thread/start` deletes the
  conversation and exits 1; `--trust` passes.
- U-state: each status of F6 to its word; an id the server does not know.
- U-stop: interrupt, wait, clean, empty list; a list that does not empty exits 1.
- U-drift: an answer without `status`, an unknown status word, an error for
  `thread/backgroundTerminals/list`: named, exit 1.

**Z: `test-claude-sessions`** (existing zsh suite, new cases). The helper is
replaced by a stand-in that logs its arguments and prints the same JSON samples
the U suite asserts the real helper prints (one sample file read by both suites).

- Z-start: lane flags with claude or with `-- args` exit 2; the window command is
  `codex resume <id>`; the id is recorded on the window; a failed window deletes
  the conversation; the prompt reaches the helper on stdin.
- Z-table: a client row takes the id of its window; STATE and MODEL in the table,
  `state`/`model`/`effort` in `--json`; server down gives `?` and exit 0.
- Z-close: idle closes and prints the resume line; working is refused; `--force`
  calls `stop` first; `--archive`; a window without a session is refused; several
  targets, one refused: exit 1 and the others closed.

**L: live checks** (`FLAKELAB_CODEX_LIVE=1 files/scripts/test-codex-threads`,
never part of `make test` or the flake check; run by the builder on a box with
Codex, and again after a Codex update). Every conversation they create is deleted
at the end, and `config.toml` is compared with its state before.

- L1: start with a cheap model at its lowest effort and a one-word prompt: the
  server reads back model and effort, the turn completes, the default in
  `config.toml` is unchanged, an unknown model is refused.
- L2: a fresh folder with `.git`: refused without `--trust`, no entry written.
- L3: a prompt that runs `sleep`: close refuses, `--force` ends the turn and the
  `sleep`, the window is gone.

## Open points for the reviewer

1. The protocol's command-line entry is labelled experimental, and
   `thread/backgroundTerminals/*` is in the experimental part of the schema. G6
   makes a change loud; it does not make it harmless.
2. The WebSocket client is written here rather than taken from a library, to keep
   the helper on the standard library like its siblings.
3. Step 2 of "Starting" repeats Codex's trust rule as measured in F11. Step 4
   catches a miss after the fact, when the folder's settings were already loaded.
4. A Codex row can now appear twice in the table (the server's row and the
   window's row, same session). `--save` already keeps one line per session.
5. If the shared server is not running, the new paths only report it.
