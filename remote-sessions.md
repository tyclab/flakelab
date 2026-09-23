# Remote sessions

How to reach, keep and continue the agent sessions on this box (Claude Code,
Codex, Kiro CLI) from somewhere else: another window, another machine, a
phone. A design proposal; the backlog entry points here.

## What is there today

- `flakelab sessions` lists the running Claude Code sessions with their ids,
  `--save` / `--autosave` record them, `--resume` prints the `claude --resume`
  lines after a restart, `--open` puts each in its own Windows Terminal tab,
  `--recent` finds the window closed by mistake. Claude Code only.
- The state root syncs transcripts and memory between machines, forks parked,
  so `claude --resume <id>` on the other box continues a session started here
  (`stateTranscripts`). Codex sessions ride the same sync.
- `remoteControlAtStartup` is written into Claude Code's settings, but only
  inside the `claudeAgentDefaults` bundle, beside the trust-related keys.
- The `proxmox-vm` target runs sshd; the `wsl` target does not, and neither has
  a terminal multiplexer, `mosh` or `tailscale` in its package set.

So a session lives exactly as long as the terminal that started it. Close the
tab, drop the SSH connection, let the laptop sleep, and the agent is gone
mid-task; the transcript survives, the work in flight does not.

## What "remote" needs

Five separate things, and each tool covers a different subset of them:

| need                                 | Claude Code                                          | Codex                       | Kiro CLI                         |
| ------------------------------------ | ---------------------------------------------------- | --------------------------- | -------------------------------- |
| a session that outlives its terminal | not the tool's job                                   | not the tool's job          | not the tool's job               |
| reach the box from elsewhere         | Remote Control relays through the vendor             | no                          | no                               |
| attach to a running session          | Remote Control, from claude.ai/code or the app       | no                          | no                               |
| continue a session later, elsewhere  | `--resume`, `--fork-session`, `--teleport`/`--cloud` | `codex resume <id>`         | `kiro-cli chat --resume-id <id>` |
| know when a session needs you        | `Notification` hook events                           | `hooks.json`, a notify hook | agent hooks (verify 4)           |

The vendor-native pieces are worth having where they exist, and they exist
only for Claude Code: Remote Control keeps a local session steerable from
the Claude app and the web as long as the `claude` process stays alive, and a
`claude remote-control` in a directory makes the machine a device card in the
app's Code tab from which a new session can be started there; `--teleport`
pulls a cloud session into a terminal and `--cloud` pushes one out. What none
of the three tools does is keep the process alive without a terminal, reach a
box that has no public address, or tell you a session is waiting on a permission
prompt while your phone is in your pocket. Those three are generic, and one
answer covers all three tools.

## Design

### The session host: tmux

Every agent session that should survive its terminal runs inside a tmux
server owned by the user, one session named `agents`, one window per agent
session, titled after the tool and the directory. A terminal, local or
remote, is a view on that window and can close at will. This is the one
mechanism that gives Codex and Kiro what Remote Control gives Claude Code,
and it is what Remote Control itself depends on: the process has to stay up.

`flakelab sessions` grows the verbs for it and drops its Claude-only scope:

```
flakelab sessions start <tool> [DIR] [-- ARGS]   a new window running the tool in DIR, attached unless --detach
flakelab sessions attach [ID|WINDOW]              attach this terminal to the window that holds a session
flakelab sessions                                 the table gains a `host` column: the tmux window, or `tty` for a bare session
flakelab sessions --open [file]                   each Windows Terminal tab now runs `tmux attach -t agents:<window>`
flakelab sessions --resume [file]                 recreates the windows: one per saved session, running the tool's resume command
```

The registry becomes tool-aware. Claude Code's `~/.claude/sessions/<pid>.json`
stays the source for Claude; a Codex session is the `codex` process and the
rollout file it holds open under `~/.codex/sessions/`; a Kiro session is the
`kiro-cli` process and the id its store records for that pid (verify 3). The
saved line is `<tool>  <dir>  <id>`, and `--resume` prints `claude --resume`,
`codex resume` or `kiro-cli chat --resume-id` accordingly. The autosave timer
records the tmux window beside each session, so a reboot brings back the
layout and not just the list.

The aliases `c`, `cc`, `codex`, `k`, `kk` stay bare. Wrapping every launch in
tmux would change the daily feel of a Windows Terminal tab for no gain on the
sessions that finish in a minute; `flakelab sessions start` is the deliberate
form for the ones that should outlive a tab, and `attach` is what a second
device does.

`tmux` joins the package set on both targets, with a minimal config shipped as
a static dotfile: a large scrollback, mouse on, the window title set by the
starter, and no key rebinding a guest would have to learn.

### Reaching the box

The `proxmox-vm` target already runs sshd. The `wsl` target gains
`services.openssh` on a non-default port, key-only, bound to the distro's own
address, so that the Windows host and anything that can reach it can attach;
the WSL2 NAT means "anything" is the host itself unless something forwards.

That something is Tailscale, behind `flakelab.tailscale.enable`, default off:
`services.tailscale` on the box, and the box then has one stable name from any
device on the tailnet, phone included, with Tailscale SSH doing the key
management. On WSL2 the client runs in userspace networking mode; the Windows
host's own Tailscale must not also claim the distro's traffic, which is the
one sharp edge (verify 1). `mosh` rides along for the flaky-link case; it
holds the terminal, tmux holds the session, and the two together are what
makes a phone's SSH app usable on a train.

From the phone, then: any SSH client to the tailnet name, `flakelab sessions`
to see what is running, `flakelab sessions attach <id>` to join it. For Claude
Code the vendor route is the better one for steering and reviewing diffs, and
it needs nothing above beyond the session being alive; the SSH route is what
covers Codex, Kiro, and the shell itself.

### Remote Control on its own switch

`remoteControlAtStartup` moves out of `claudeAgentDefaults` into its own
option, `flakelab.claudeRemoteControl`, default off, so that an operator can
have every session steerable from the app without adopting the auto-mode
trust bundle, and the reverse. The four telemetry-gating variables that
Remote Control's feature flags need are cleared by whichever of the two
options is on. Nothing else changes in `claude.nix`; the docs say Remote
Control is on server-side for Pro and Max and needs no flag.

### Knowing when a session needs you

A Claude Code `Notification` hook fires for `permission_prompt`,
`idle_prompt`, `agent_needs_input` and the `quota_auto_resume_*` events, with
`session_id`, `cwd` and the event name in its input. `flakelab notify`, one
small script, turns that into a push: an `ntfy` topic (self-hosted or
ntfy.sh, the URL and token from `secrets.env` at use time, never in the
flake) with the session's name, the directory, the event, and the one-line
`flakelab sessions attach <id>` that answers it. The hook is written into
`settings.json` by `claude.nix` the way the `SessionEnd` state-sync hook
already is, owned by its command so a hand-added hook is left alone, and only
while `flakelab.notify.enable` is on. Codex's `hooks.json` gets the same
command on its notify event; Kiro's agent hooks are verify 4.

This is the cheapest of the four pieces and the one that changes the most:
most of the time the question from the other device is not "let me type" but
"is it waiting on me".

### Handoff between machines

Already there for Claude Code through the state root and `--resume`, and for
Codex through the same sync. What is missing is the last mile: `flakelab
sessions --resume` on the other box lists only sessions that box saw running.
`--recent` already reads the transcripts; it learns the tool column and the
state root's synced sessions, so "continue what I was doing on the desktop"
is `flakelab sessions --recent` on the laptop followed by the printed command,
forked (`--fork-session`) when both boxes may carry on.

### Options

```nix
flakelab = {
  claudeRemoteControl = false;   # remoteControlAtStartup on its own
  tailscale.enable    = false;   # services.tailscale; Tailscale SSH on
  notify.enable       = false;   # the Notification hook into ntfy; endpoint from secrets.env
  sshdWsl             = false;   # sshd on the wsl target, key-only, non-default port
};
```

### Implementation and phases

zsh for the two scripts, as every sibling; `tmux`, `mosh` and `tailscale`
from nixpkgs; the sshd and tailscale services in `nix/targets/`. The sessions
suite gains fixtures for the Codex and Kiro registries and a `tmux` stub that
records what was started and attached; `notify` gets a suite with a `curl`
stub. Phases:

1. `tmux` in the package set, `flakelab sessions start|attach`, the `host`
   column, `--open` attaching instead of resuming, autosave recording the
   window. Usable the day it lands, on WSL from a Windows Terminal tab.
2. Codex and Kiro sessions in the registry, the saved-line tool column, the
   per-tool resume commands.
3. `flakelab.claudeRemoteControl`; `flakelab notify` and the hooks.
4. sshd on WSL, `mosh`, `flakelab.tailscale.enable`; the README's "from the
   phone" walk-through.
5. `--recent` over the state root, the cross-machine handoff.

## Verify before building

1. **Tailscale under WSL2** on the operator's setup: userspace networking, the
   host's own Tailscale client, and whether Tailscale SSH or plain sshd is the
   less surprising of the two there.
2. **Remote Control's behaviour when the host sleeps or the network drops**:
   the docs say the terminal must stay running and nothing about sleep; a
   session inside tmux on a box that stays up sidesteps the question, a
   laptop does not.
3. **How Kiro CLI records a running session** (where the id lives for a
   `kiro-cli chat` process) and whether Codex's rollout file is held open for
   the life of the process, which is what lets `/proc` attribute it.
4. **Kiro's hook events**: whether an agent hook fires when the CLI waits on a
   permission or on input, with enough in its input to name the session.
5. **Whether a session started inside tmux still shows up for Remote
   Control** and in the app's device card; there is no reason it would not,
   and it is the whole premise, so it is the first thing to try.
