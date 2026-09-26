# Remote sessions

How to reach, keep and continue the agent sessions on this box (Claude Code,
Codex, Kiro CLI) from somewhere else: another window, another machine, a
phone. Every phase is on this branch; what remains is the list of things to
verify on a real box before relying on each.

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

`flakelab sessions` hosts sessions in tmux and knows all three tools:

```
flakelab sessions --start <tool> [dir] [--detach] [-- args...]   claude|codex|kiro in dir, in its own window of the `agents` session, attached
flakelab sessions --attach [id|window]                           join the window holding a session id, or a window by name; none: the server
flakelab sessions                                                the table, with TOOL and HOST columns
flakelab sessions --open [file]                                  WSL: each tab attaches a window that outlives it (tmux on PATH), else as before
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
- **Codex and Kiro.** A `codex` process is identified by the rollout file it
  holds open under `~/.codex/sessions/`; a `kiro-cli` process by the locked
  entry in Kiro's registry, `~/.kiro/sessions/cli/<id>.json` with its `.lock`,
  in the process's directory. Saves carry a tool column and `--resume` prints
  `codex resume <id>` and `kiro-cli chat --resume-id <id>`; `--recent` reads
  both tools' stores.
- **Nothing forces tmux.** The aliases `c`, `cc`, `codex`, `k`, `kk` stay
  bare; a session that finishes in a minute does not need a host.
  `--start` is the deliberate form for the ones that should outlive a tab.
- **A profile session is a session.** One started by `flakelab accounts run`
  keeps its registry entry under the profile; the table finds it there and
  `--recent` reads the transcripts a profile kept for itself.

`flakelab notify` is the push: a Claude Code `Notification` hook
(`flakelab.notify.enable`, the types in `flakelab.notify.events`) and Codex's
`notify` hook call it, and it posts to an ntfy topic the event, the directory
and the one line that answers it (`flakelab sessions --attach <id>`,
`codex resume <id>`). The topic URL and token are `NTFY_URL` and `NTFY_TOKEN`
in `secrets.env`, read at use time; a hook run never fails its caller, so an
unconfigured or offline box costs nothing. `--dry-run` shows the request,
`--title`/`--message` send one by hand. Kiro has no such event. For Codex, the
line in `~/.codex/config.toml` is:

```toml
notify = ["flakelab", "notify", "--codex"]
```

Reaching the box is the tunnel plus one thing per target: `flakelab.mosh.enable`
puts a mosh-server beside the VM's sshd (UDP 60000 to 61000, opened by the
module), and for a WSL distro `files/config/windows/enable-openssh-host.ps1`
turns on OpenSSH Server on the Windows host, port 22 from the WireGuard subnet
only, keys only, with the login landing in `wsl.exe -d <distro>`. With a state
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
two scripts that already know the state, `accounts` and `claude-sessions`.
The page shows every stored login with its windows as bars, an active or
profile or quarantined tag and a switch button, drift when a login was made
by hand, the running sessions with their tmux window and directory, a form
that starts one in tmux (`--start <tool> <dir> --detach`), "poll usage now",
"what would auto do?" (the engine's dry run, its events in the log), and a
link to the terminal when one is on. Every write is one CLI call, so the
CLI's locks, refusals and exit codes hold (a refusal comes back as 409 with
the CLI's reason); the server never reads a token file of a tool and never
touches the network itself.

It binds to 127.0.0.1:8321 unless told otherwise and refuses every-interface
binds; every API call needs the bearer token from
`~/.local/state/flakelab/web/token` (0600, made on the first start,
`flakelab web --print-token` shows it), which the page asks for once and
keeps in the browser. `flakelab.web.enable` runs it as the user service
`flakelab-web` on `flakelab.web.bind`; the box's WireGuard address is the
one to name for a phone.

The terminal beside it is ttyd, `flakelab.web.terminal`: a browser tab
attached to the `agents` tmux session (created when absent), on the same
address, basic auth with user `flakelab` and the same token as the password.
That is the "no SSH app on the phone" option from the table above, at the
price it names: a shell in a browser tab behind a long-lived token. Keep it
on the tunnel.

```nix
flakelab.web = {
  enable       = true;
  bind         = "10.66.0.2";   # this box's WireGuard address
  port         = 8321;
  terminal     = true;
  terminalPort = 7681;
};
```

## What the vendors give

**Claude Code, Remote Control.** `claude remote-control` in a project
directory runs a server that shows up in the session list at claude.ai/code
and in the app's Code tab (a computer icon with a green dot); from there new
sessions start on the machine, in that directory (`--spawn same-dir`, the
default) or in a worktree, up to `--capacity` (32). `claude --remote-control`
makes one interactive session steerable, `/remote-control` does it
mid-session, and `remoteControlAtStartup: true` in the user settings does it
for every session. It reconnects by itself after sleep or a network drop,
queueing prompts and permission dialogs meanwhile; server mode gives up after
about ten minutes of outage, and a stopped server's sessions can be re-served
for about four hours (`--continue`, `--session-id`). Outbound HTTPS only, no
inbound port. It needs a full claude.ai login (not a setup token), a plan that
allows it, and the four telemetry variables unset. Push notifications
("push when actions required") come with it in the app. Channels (Telegram,
Discord into a running session) are the other vendor route for steering.

**Codex** has `codex resume <id>`, cloud tasks, and a `notify` hook in
`config.toml` that runs a command when a turn completes. No remote control of
a local session.

**Kiro** has `kiro-cli chat --resume-id <id>`, `--resume-picker` and
`--list-sessions`; its hooks (`SessionStart`, `Stop`, `UserPromptSubmit`,
`PreToolUse`, `PostToolUse`, and the file and task events) fire on turns,
never on a permission prompt or a wait for input, which is visible only in
its TUI.

## The plan

Phases, each shippable on its own. All five are on this branch.

1. **tmux as the session host** — done: `--start`, `--attach`, the host
   column, `--open` attaching, Codex and Kiro in the registry, saves with a
   tool column.
2. **Remote Control on its own switch** — done: `flakelab.claudeRemoteControl`,
   default off, writes `remoteControlAtStartup` and clears the four variables
   Remote Control's feature flags need, so a box can have every session
   steerable from the app without adopting the auto-mode trust bundle;
   `claudeAgentDefaults` still implies it.
3. **A push when a session waits on you** — done: `flakelab notify`
   (`files/scripts/notify`, `test-notify`), the `Notification` hook behind
   `flakelab.notify.enable` written into `settings.json` the way the
   `SessionEnd` state-sync hook is, owned by its command; Codex's `notify`
   line documented above. Redundant with the Claude app's push where Remote
   Control is on; it is for Codex and for anyone without the app.
4. **Reaching the box** — done, on the tunnel rather than a mesh product:
   - `proxmox-vm` already runs sshd; `flakelab.mosh.enable` adds
     `programs.mosh`, default off. Nothing else: the VM's WireGuard address
     is the one to dial.
   - `wsl` gets nothing inside the distro. NixOS-WSL forces the firewall
     unit off, so no port can be opened here; under NAT the host reaches the
     distro's ports through `localhost` while the LAN needs `netsh portproxy`
     (TCP only, so no mosh) or mirrored networking; and a second tunnel
     client inside WSL2 beside the host's is the encapsulation-in-
     encapsulation case every mesh vendor warns about. The clean route needs
     nothing in the distro: OpenSSH Server on the Windows host, port 22 from
     the WireGuard subnet only, keys only, the login landing in
     `wsl.exe -d <distro>`, one `flakelab sessions --attach` away.
     `files/config/windows/enable-openssh-host.ps1` is the script, idempotent.
5. **Handoff between machines** — done: `flakelab sessions --recent` reads the
   state root's synced transcripts beside the local ones, marking the ones
   not yet pulled to this box, so "continue what I was doing on the desktop"
   is one printed line on the laptop (after `flakelab backup --state-only`),
   forked with `--fork-session` when both boxes may carry on.

### Options

```nix
flakelab = {
  notify.enable       = false;   # the Notification hook into ntfy; endpoint from secrets.env
  notify.events       = [ "permission_prompt" "idle_prompt" "agent_needs_input"
                          "quota_auto_resume_pending" "quota_auto_resume_fired" ];
  mosh.enable         = false;   # proxmox-vm only; mosh-server beside sshd
  claudeRemoteControl = false;   # phase 2
};
```

## Verify on a box

1. **A session started inside tmux shows up for Remote Control** and in the
   app's session list. The docs say tmux is the way to keep one alive over
   SSH, so there is no reason it would not, and it is the premise of the
   whole stack: the first thing to try on the box.
2. **Windows OpenSSH Server on the host, over WireGuard,** as the WSL entry:
   that `ssh host` from the phone lands in a shell from which
   `wsl.exe -d <distro> -- zsh -lc "flakelab sessions --attach"` works, and
   whether the `DefaultShell` block at the end of the script should be on.
3. **mosh on the VM** from a phone client across a network change, and how it
   behaves with a tmux view (it should be invisible).
4. **`claude agents --json`** as a second source for the registry: the docs
   list running sessions from it with `pid`, `sessionId`, `cwd` and `name`,
   but say interactive sessions in other terminals may not appear until
   backgrounded; if they do appear, the `/proc` walk becomes a fallback.
5. **Kiro's lock file contents** (a pid would let two chats in one directory
   be told apart without an open file) and whether a headless
   `kiro-cli chat --no-interactive` writes a registry entry at all.
6. **The ntfy payload on the phone**: that a `Title:` of `claude - <dir>` and
   the three-line body read well, and whether `permission_prompt` at priority
   4 should be 5 (urgent, overrides do-not-disturb).
7. **Codex's `notify` payload fields** on the installed version: `cwd` and
   `thread-id` are taken when present, `turn-id` otherwise; the body degrades
   to the type alone if neither is there.
8. **The dashboard from a phone** on the tunnel: that the page renders at
   phone width, that a switch from it lands (the CLI's transaction, the
   engine's refusals), and that ttyd's basic auth prompt and tmux under it
   are usable on a touch keyboard.
