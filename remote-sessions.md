# Remote sessions

How to reach, keep and continue the agent sessions on this box (Claude Code,
Codex, Kiro CLI) from somewhere else: another window, another machine, a
phone. The first phase is implemented (`flakelab sessions --start` /
`--attach`); the rest is the plan, with what to verify before each step.

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
or sleeps) and reachability across NAT. Those are mosh and Tailscale. So the
stack is three separate answers to three separate problems, plus the vendor
layer on top where one exists:

| problem                              | answer                                       | why not the alternatives                                                                                     |
| ------------------------------------ | -------------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| a session outlives its terminal      | tmux, one `agents` session per box           | zellij looks nicer, but every SSH app, Windows Terminal and the vendor tools know tmux, and it is scriptable |
| a flaky link, a changing IP, sleep   | mosh over SSH                                | Eternal Terminal does the same over TCP; mosh is in nixpkgs and in every mobile SSH client                   |
| a box with no public address         | Tailscale                                    | port-forwarding through a home router is fragile; a self-hosted relay is one more daemon to own              |
| steer a Claude session, review diffs | Claude's Remote Control, in addition         | needs the process alive, which tmux gives it; covers Claude only                                             |
| know a session is waiting on you     | the Claude app's push, else a hook into ntfy | from a phone the question is usually "is it stuck", not "let me type"                                        |

The third-party phone apps (Termote, MobileCLI, MuxCLI, ServerCC, happy,
omnara) all reduce to tmux or a PTY plus somebody's relay; the relay is the
part not worth depending on when Tailscale gives the same reach from any SSH
client. A browser terminal (ttyd behind `tailscale serve`) is the one
alternative worth keeping as a later option: no SSH app on the phone, at the
price of a shell in a browser tab behind a long-lived token.

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
  window, so two terminals can look at two windows. A view is set to go away
  with its last client (`destroy-unattached keep-last`; a tmux before 3.4
  leaves it behind, harmlessly). Inside tmux already, `--attach` switches the
  client instead of nesting.
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

The tmux config (`files/config/tmux/tmux.conf`, via `programs.tmux`) keeps
the defaults a guest already knows: a large scrollback, mouse on, window
titles set by the starter, no key rebinding.

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

Phases, each shippable on its own. Phase 1 is on this branch.

1. **tmux as the session host** — done: `--start`, `--attach`, the host
   column, `--open` attaching, Codex and Kiro in the registry, saves with a
   tool column.
2. **Remote Control on its own switch.** `remoteControlAtStartup` moves out
   of `claudeAgentDefaults` into `flakelab.claudeRemoteControl`, default
   off, so a box can have every session steerable from the app without
   adopting the auto-mode trust bundle, and the reverse; whichever of the two
   is on clears the four variables Remote Control's feature flags need.
3. **A push when a session waits on you.** A Claude Code `Notification` hook
   (`permission_prompt`, `idle_prompt`, `agent_needs_input`, the
   `quota_auto_resume_*` events; the hook input carries `session_id`, `cwd`,
   `notification_type`) and Codex's `notify` command call `flakelab notify`,
   which posts to an ntfy topic (URL and token from `secrets.env` at use
   time) the session's name, the directory, the event and the one line
   `flakelab sessions --attach <id>` that answers it. Written into
   `settings.json` the way the `SessionEnd` state-sync hook is, owned by its
   command, only while `flakelab.notify.enable` is on. Redundant with the
   Claude app's push where Remote Control is on; it is for Codex and for
   anyone without the app. Kiro has no such event.
4. **Reaching the box.** Different on the two targets, and the WSL side is
   where the research changed the plan:
   - `proxmox-vm` already runs sshd. It gains `programs.mosh` (UDP 60000 to
     61000, opened by the option) and `services.tailscale` with Tailscale SSH
     (`tailscale set --ssh`, port 22, sshd untouched), both behind options,
     default off.
   - `wsl` does not get sshd, mosh or Tailscale inside the distro. Tailscale
     documents that running it inside WSL2 beside the Windows client breaks
     (encapsulation inside encapsulation) and recommends the host only;
     NixOS-WSL forces the firewall unit off, so nothing here can open a port
     anyway; and under NAT the host reaches the distro's ports through
     `localhost` while the LAN needs `netsh portproxy` (TCP only, so no mosh)
     or mirrored networking (Windows 11 22H2+). The clean route is the one
     that needs nothing in the distro: Tailscale and OpenSSH Server on the
     Windows host, and the login lands in `wsl.exe -d <distro>`, one
     `flakelab sessions --attach` away. A `files/config/windows/` note with
     the three PowerShell lines is the deliverable, plus a `setup-wsl-nix.ps1`
     switch if it is wanted unattended.
5. **Handoff between machines.** Already there for Claude Code and Codex
   through the state root and `--resume`; the last mile is
   `flakelab sessions --recent` reading the synced transcripts so "continue
   what I was doing on the desktop" is one printed command on the laptop,
   forked (`--fork-session`) when both boxes may carry on.

### Options (phases 2 to 4)

```nix
flakelab = {
  claudeRemoteControl = false;   # remoteControlAtStartup on its own
  notify.enable       = false;   # the Notification hook into ntfy; endpoint from secrets.env
  mosh.enable         = false;   # proxmox-vm only
  tailscale.enable    = false;   # proxmox-vm only; Tailscale SSH on
};
```

## Verify before the next phases

1. **A session started inside tmux shows up for Remote Control** and in the
   app's session list. The docs say tmux is the way to keep one alive over
   SSH, so there is no reason it would not, and it is the premise of the
   whole stack: the first thing to try on the box.
2. **Windows OpenSSH Server plus Tailscale on the host** as the WSL entry:
   that `ssh host` from the phone lands in a shell from which
   `wsl.exe -d <distro> -- tmux attach` works, and whether the login shell
   should be that command outright.
3. **mosh on the VM** from a phone client across a network change, and how it
   behaves with a tmux view (it should be invisible).
4. **`claude agents --json`** as a second source for the registry: the docs
   list running sessions from it with `pid`, `sessionId`, `cwd` and `name`,
   but say interactive sessions in other terminals may not appear until
   backgrounded; if they do appear, the `/proc` walk becomes a fallback.
5. **Kiro's lock file contents** (a pid would let two chats in one directory
   be told apart without an open file) and whether a headless
   `kiro-cli chat --no-interactive` writes a registry entry at all.
