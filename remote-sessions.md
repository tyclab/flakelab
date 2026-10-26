# Remote sessions

How to reach, keep and continue the agent sessions on this box (Claude Code,
Codex) from somewhere else: another window, another machine, a
phone.

## The question underneath

"Can a remote shell stay open when SSH disconnects, or is SSH even the right
thing?" Two answers, because those are two problems.

A shell dies with its SSH connection because its controlling terminal went
away, not because SSH is the wrong protocol. Keeping a process alive without a
terminal is a multiplexer's job: a tmux server owns the pane, the agent keeps
running, any terminal reattaches later. Claude Code's own documentation says
the same for Remote Control: to keep a session running on a remote machine
after you disconnect from SSH, start it inside tmux or screen.

SSH is the right transport: every tool, every device, key auth, nothing in the
path you do not own. What SSH lacks is roaming (a phone that changes networks
or sleeps) and reachability across NAT. Those are mosh and the WireGuard
tunnel every box here is already on. So the stack is three separate answers
to three separate problems, plus the vendor layer on top where one exists:

| problem                              | answer                                       | why not the alternatives                                                                                      |
| ------------------------------------ | -------------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| a session outlives its terminal      | tmux, one `agents` session per box           | zellij looks nicer, but every SSH app, Windows Terminal and the vendor tools know tmux, and it is scriptable  |
| a flaky link, a changing IP, sleep   | mosh over SSH                                | Eternal Terminal does the same over TCP; mosh is in nixpkgs and in every mobile SSH client                    |
| a box with no public address         | WireGuard, already there                     | port-forwarding through a home router is fragile; a mesh product would be a second overlay for the same reach |
| steer a Claude session, review diffs | Claude's Remote Control, in addition         | needs the process alive, which tmux gives it; covers Claude only                                              |
| know a session is waiting on you     | the Claude app's push, else a hook into ntfy | from a phone the question is usually "is it stuck", not "let me type"                                         |

The third-party phone apps (Termote, MobileCLI, MuxCLI, ServerCC, happy,
omnara) all reduce to tmux or a PTY plus somebody's relay; the relay is the
part not worth depending on when the tunnel gives the same reach from any SSH
client. A browser terminal (ttyd on the WireGuard address) is the one
alternative worth keeping: no SSH app on the phone, at the price of a shell
in a browser tab behind a long-lived token; `flakelab web` (below) is that
option, with the dashboard beside it.

## What is implemented

`flakelab sessions` hosts sessions in tmux and knows both tools:

```
flakelab sessions --start <tool> [dir] [--detach] [-- args...]   claude|codex in dir, in its own window of the `agents` session, attached
flakelab sessions --attach [id|window]                           join the window holding a session id, or a window by name; none: the server (at a terminal, a list of the windows first)
flakelab sessions                                                the table, with TOOL and HOST columns
flakelab sessions --open [file]                                  WSL: each tab attaches a window that outlives it (tmux on PATH), else as before; a running session gets a tab on its window, never a second process
```

Mechanics worth knowing:

- **Windows and views.** Every `--start` window lives in the one `agents`
  session, named `<tool>-<directory>`. A terminal never attaches `agents`
  itself: `--attach` and `--open` create a grouped session (a "view",
  `agents-<window>-<pid>`) that shares the windows but has its own current
  window, so two terminals can look at two windows. A view goes away with
  its client through a `client-detached` hook that kills it (not
  `destroy-unattached`: since tmux 3.4 that option destroys a detached
  session as soon as the command that set it disconnects, before the
  terminal attaches). Inside tmux already, `--attach` switches the client
  instead of nesting. A window's command runs with the tmux server's
  environment, and the server is born by whoever starts the first window,
  so `--start` hands the window the caller's PATH (`-e`): the tool resolves
  the same way it did for the caller, whether the server came from a
  terminal, the dashboard's service or ttyd.
- **The host column.** A process is placed by walking its parents until one
  is the pane process of an `agents` window (`tmux list-panes -a`), so a
  session started by hand inside a window is found too, not only `--start`'s.
- **The environment.** The tmux server inherits the environment of the shell
  that starts it, which is what carries `secrets.env`, `PATH` and the agent
  socket into every later window. A server started from a shell without them
  keeps lacking them until it is restarted.
- **Discovery and safe saves.** Claude's local PID registry also finds sessions
  whose process name is a version number, after checking the live executable.
  Manual saves and autosaves replace complete files atomically; scratch files
  use the state sync's excluded naming pattern. Machine-specific snapshot names
  keep same-hostname instances from overwriting or pruning each other's saves.
- **Codex.** All user rollouts held open by a `codex` process are listed,
  including multiple conversations in a shared app-server. Each uses its
  transcript's directory; internal subagents and daemon supervisors are excluded.
  A CLI client may show no ID because its server owns the transcript; the
  server's identified sessions are still saved. Saves carry a tool column and `--resume`
  prints `codex resume <id>`; `--recent` reads both tools' stores.
- **Nothing forces tmux.** The aliases `c`, `cc`, `codex` stay bare; a
  session that finishes in a minute does not need a host.
  `--start` is the deliberate form for the ones that should outlive a tab.
- **Rotation groups survive recovery.** Fable and Opus/other sessions retain
  their group, profile and actual migrated conversation id in snapshots.
  Starting or moving a conversation into a group is explicit; existing
  sessions keep running. See [session-groups.md](session-groups.md).
- **A profile session is a session.** One started by `tycswap run`
  keeps its registry entry under the profile; the table finds it there and
  `--recent` reads the transcripts a profile kept for itself.

`flakelab.questions.enable = true;` registers `flakelab-questions` in both
Claude and Codex. Its `ask_question` tool posts the full question, optional
context and choices to Home Assistant, then returns your phone or inbox answer
to the original tool call. Tapping the push opens that question in HA's
**Agent questions** sidebar; replies and closed questions remain there for up
to seven days (500 records maximum). No daemon or event observer runs on the
agent box: each client starts the same stdio server.

In Claude Code and Codex the question also opens as a native terminal dialog
(MCP elicitation): the choices numbered under the question and one field that
takes a number, a choice's text or prefix, or your own words, so a choice is
"2", Enter, Enter. Claude Code cuts each message line at the terminal width and
shows three lines, so the question is wrapped at 100 characters first; when it
fills the message, one line of choices moves under the field instead, and
choices that need more room keep a picker list beside the free-text field.
The dialog goes out before the inbox post, one dialog at a time per session. The
first answer wins: a phone or inbox answer closes the dialog, a terminal answer
is recorded in the inbox as delivered with `source: terminal` through hatyc's
`answer` op and clears the push. Declining or dismissing the dialog leaves the
question open for the phone. Without elicitation (headless runs, other MCP
hosts) the inbox path alone is used; against a hatyc without the `answer` op the
push is cancelled instead and the result says `inbox: unsupported`; with HA down
the dialog still answers and the result says `inbox: unavailable`.

This needs the `flakelab_questions` HA integration from hatyc. It reads
`NOTIFY_WEBHOOK_URL` at runtime and adds `-questions` to the webhook ID. Keep
`sopsKeyFiles.NOTIFY_WEBHOOK_URL = null;`. The endpoint accepts LAN POSTs only;
HA authentication protects inbox replies. A separate random capability per
question binds polling to its originating call; phone actions use a different
one-use reply nonce. Cancelling the call closes its question. A dead process
expires within 90 seconds; the overall answer window is 25 minutes. An expired
or cancelled call returns no fabricated answer. Questions are not approval
grants, and native dialogs are not intercepted: the agent must call this tool.

The managed client instructions prefer it for clarification and decisions.
Claude may move a long call to a background task; dependent work must still
wait for its answer. Codex and Claude get a per-server timeout just above the
answer window. Existing sessions need to reconnect MCP or restart to load a
new server or to get the dialog. If HA is unavailable and no dialog is open, ask
in the conversation.

`flakelab notify` remains available for manual and legacy pushes: a Claude Code `Notification` hook
(`flakelab.notify.enable`, the types in `flakelab.notify.events`) and Codex's
`notify` hook call it, and it posts the event, the directory and the one line
that opens its session (`flakelab sessions --attach <id>`, `codex resume <id>`) to an
ntfy topic (`NTFY_URL`, `NTFY_TOKEN`), to a JSON webhook (`NOTIFY_WEBHOOK_URL`,
a body of `title`, `message`, `priority` 1-5 and `tags`; Home Assistant's
`/api/webhook/<id>` takes it as `trigger.json`), or to both. A target the
environment lacks is read at use time from the sops render or `secrets.env`;
the webhook URL is its credential, so it is never on a command line or in
output, and `sopsKeyFiles.NOTIFY_WEBHOOK_URL = null;` keeps it out of the
shell's environment too.
A hook run never fails its caller, so an unconfigured or offline box costs
nothing. `--dry-run` shows the request,
`--title`/`--message` send one by hand. For Codex, the
legacy line in `~/.codex/config.toml` is below. It reports every completed turn,
not a waiting question, and carries no reply route. Remove it when using the
question tool:

```toml
notify = ["flakelab", "notify", "--codex"]
```

Reaching the box is the tunnel plus one thing per target: `flakelab.mosh.enable`
puts a mosh-server beside the VM's sshd (UDP 60000 to 61000, opened by the
module), and for a WSL distro `files/config/windows/enable-openssh-host.ps1`
turns on OpenSSH Server on the Windows host, port 22 from the WireGuard subnet
only, keys only, with the login landing in `wsl.exe -d <distro>`. Nothing is
opened inside the distro: NixOS-WSL forces its firewall off, the LAN reaches
a NAT-ed distro only through `netsh portproxy` (TCP, so no mosh), and a second
tunnel client inside WSL2 beside the host's is tunnel-in-tunnel. With a state
root, `flakelab sessions --recent` also lists the sessions another box synced
there and not yet pulled here, marked as such, so continuing the desktop's
session on the laptop is one line after a `flakelab backup --state-only`;
`claude --resume <id> --fork-session` when both boxes may carry on.

The tmux config (`files/config/tmux/tmux.conf`, via `programs.tmux`) keeps
the defaults a guest already knows: a large scrollback, mouse on, window
titles set by the starter, no key rebinding.

## The browser front end

`flakelab web` is the dashboard: one python3 process from the standard
library serving `files/config/web/index.html` and a small JSON API over the
two commands that already know the state, `tycswap` and `claude-sessions`.
The page shows every stored login with its windows as bars, an active,
disabled or at-limit tag and a switch button, the running sessions with their
tmux window and directory, a form that starts one in tmux
(`--start <tool> <dir> --detach`), and a link to the terminal when one is on. It
reloads every 15 seconds while the tab is visible. Every write is one CLI call, so the
CLI's locks, refusals and exit codes hold (a refusal comes back as 409 with
the CLI's reason); the server never reads a token file of a tool and never
touches the network itself.

It binds to 127.0.0.1:8321 unless told otherwise and refuses every-interface
binds; every API call but `/api/health` needs the bearer token from
`~/.local/state/flakelab/web/token` (0600, made on the first start,
`flakelab web --print-token` shows it), which the page asks for once and
keeps in the browser. `flakelab.web.enable` runs it as the user service
`flakelab-web` on `flakelab.web.bind`; the box's WireGuard address is the
one to name for a phone. On the proxmox-vm target that address opens the
port in the NixOS firewall, which otherwise leaves only sshd open. A WSL
distro gets no rule: NixOS-WSL turns its firewall off, so the dashboard
listens on whatever `bind` names, and what reaches that address from another
machine is the Windows host's networking and firewall to decide.

The terminal beside it is ttyd, `flakelab.web.terminal`: a browser tab
attached to the `agents` tmux session (created when absent). ttyd listens on
a Unix socket in the user's runtime directory with no credential of its own
(ttyd takes one only on its command line, where `/proc` shows it to every
user, and logs it at start); the dashboard is its only door. "terminal ↗"
asks `POST /api/terminal` with the bearer for a session cookie scoped to
`/terminal` (HttpOnly, SameSite=Strict, 12 hours), and `/terminal/` with
that cookie is tunnelled to the socket as it came, WebSocket included.
`flakelab web --rotate-token` replaces the token in the file; the server
compares against the file on every check, so it follows at once and every
terminal session ends with the old token. That is the "no SSH app on the
phone" option from the table above, at the price it names: a shell in a
browser tab behind a long-lived token. Keep it on the tunnel.

Copying out of the session: in a terminal app (Windows Terminal, an SSH app),
a mouse drag selects in tmux and the selection lands on the device's
clipboard, from a nested tmux over SSH too, and a long URL copies whole even
where tmux wrapped it. ttyd's browser terminal cannot receive that copy (its
xterm.js has no OSC 52 handler); there, Shift+drag selects in the browser
instead, one screen row at a time.

The server also refuses a request whose `Host` is not its own address
(421), so a page elsewhere that rebinds a name to it gets nothing, and drops
a connection idle for 30 s before its request, so idle connections cannot
hold its threads.

```nix
flakelab.web = {
  enable   = true;
  bind     = "10.66.0.2";   # this box's WireGuard address
  port     = 8321;
  terminal = true;
  logo     = ./web-logo.svg; # the heading mark and tab icon, served at /logo
};
```
