# Runtime protection: the box outlives its agent workload

Date: 2026-11-11. Repo: `tyclab/flakelab` (`nix/targets/wsl.nix`,
`nix/configuration.nix`, `nix/options.nix`, `nix/home/`,
`files/scripts/claude-sessions`, `nix-doctor`, new scripts, `known-issues.md`). The
private overlay sets the per-box values.

## Intent

On 2026-11-11 the GamerTyc box lost its WSLg display layer and, 70 minutes later,
every agent session. The operator's brief, in their words: "evalute a good way to
make sure to protect wsl runtime. wslg dies then i need to do a shutdown that sucks.
coordinate with oder session running that workload. your job is to think bigger. also
note we have multipole installs so it must work on different sets of hardware".

Three rules follow from the evidence below:

1. The runtime (systemd, the user manager, tmux, flakelab's services) outlives the
   workload (agent sessions and what they start).
2. What dies comes back without the operator.
3. Every limit is a share, so one mechanism fits every box; a box whose needs differ
   states its own share in the overlay.

## Rulings

- WSLg default, asked 2026-11-11 ("Turn WSLg off by default on every flakelab WSL
  box, with a per-box opt-in?"): "Off by default (Recommended)".
- Follow-up the same hour: "check if wslg on and hardened isnt better default web
  research implication community". The research is below. It was answered before
  the mount finding in "Evidence, WSLg": that finding makes "on, hardened" cheap,
  so the choice per box is put to the operator again when PR B is ready.
- "i think rdp is also our issue since i do this from elitebnook to this device and
  on elitebook never had the issue", then "but i havent done that today and since pc
  rebooted there seem to be at least one other cause". The evidence agrees with the
  second message: no Remote Desktop connection is needed for the crash.
- How to proceed: "Spec PR first (Recommended)".
- Earlier the same day, on the Docker memory limit (PR 375): "make that change still
  sense?", then "Revert" (PR 376). Containers are out of scope here.

## Evidence

All times CET, 2026-11-11, GamerTyc (16 threads, VM 32 of 64 GB, 8 GB swap, WSL
3.0.5.0, WSLg 1.0.79, systemd 260.5), unless a line says otherwise.

### WSLg

- 13:55:59.702 `weston.log`: `RDP clipboard_data_source_send new (…:published) vs prev
(…:cancel pending): outstanding RDP data request (client to server)`; 0.55 s later
  `stderr.log`: weston "terminated with signal 11". The line also appears at
  12:18:58, 12:22:35 and 12:22:39 without a crash. A crash followed it on
  2026-11-09 15:46:59 and 2026-11-10 16:54:33.
- WSLGd relaunched weston 10 times in 2.6 s. Each attempt logged `unlinking stale
lock file /tmp/.X0-lock`, then `failed to bind to /tmp/.X11-unix/X0: Address
already in use`, and segfaulted.
- Why the bind fails: NixOS-WSL's unit `tmp-.X11\x2dunix-X0.mount`
  (`modules/wsl-distro.nix`, "Make sure the WSLg X11 socket is available if /tmp is
  mounted to something else") bind-mounts the socket file itself. `mountinfo` shows
  `X0` as a mountpoint in the distro and, through the shared mount group, inside the
  WSLg system distro (`/mnt/wslg/.X11-unix/X0` and `/tmp/.X11-unix/X0`). weston
  unlinks the socket before it binds (weston-mirror `xwayland/launcher.c`), and a
  mountpoint cannot be unlinked. On a stock distro weston returns after such a
  crash: the reporter of microsoft/wslg #1525 crashed it twice 4 s apart.
- The unit is redundant here: `/tmp` is not a filesystem of its own, and WSL itself
  mounts `/mnt/wslg/.X11-unix` on `/tmp/.X11-unix`.
- `WSLGd/ProcessMonitor.cpp`: a child that exits more than 10 times in 60 s is "not
  starting it again"; WSLGd keeps running. weston hit that cap. `msrdc.exe` exits once
  per 31 s, never hits it, and is relaunched forever: 149 launches by 15:32, each
  taking the keyboard focus.
- Proven on the box at 15:33:07: ending `C:\Program Files\WSL\msrdc.exe` 9 times
  within 49 s made WSLGd log the cap for msrdc; no relaunch since. The focus loop
  ends without `wsl --shutdown`.
- Upstream, all open: microsoft/wslg #1407 (race on quick successive copies, since
  2026-01), #1525 (16 core dumps, "several times a day"), #1524 (a pending request
  has no timeout; `msrdc.exe` then holds the Windows clipboard open for 5 to 106 s),
  #678. No release note of WSL up to 3.0.5 or WSLg up to 1.0.79 names a fix. The one
  workaround named there is the clipboard bridge off.
- The clipboard switch this build reads is `WESTON_RDP_CLIPBOARD` (weston-mirror
  `compositor/main.c`: `read_rdp_config_bool("WESTON_RDP_CLIPBOARD", true)`; the
  string is in the installed `libexec_weston.so`). The wiki's
  `WESTON_RDP_DISABLE_CLIPBOARD` is not read. WSLGd applies `[system-distro-env]`
  keys of `%USERPROFILE%\.wslgconfig` with `setenv`.
- Nothing on the box used WSLg: no X or Wayland client at 15:25, no GUI process.
  Logins use the Windows browser.
- Windows' `TerminalServices-LocalSessionManager` log, last 3 days: two local logons,
  no remote connection.
- Load at the three crashes: `node_load1` 16.2, 16.5 and 37.0 on 16 threads. The box
  is above 16 for 23 % of the time; the EliteBook (12 threads, VM 12.5 GB, no crash)
  for 0.4 %, median 0.18. Consistent with a starved VM widening the race; three
  events do not prove it.
- WSL 3.0.5 release notes: "Fix guiApplications config parsing" (#41973); which
  earlier releases misread the key is not established.
- `.wslconfig` on GamerTyc holds `[experimental] autoMemoryReclaim=Gradual`, written
  by hand; no flakelab code reads or writes `.wslconfig` or `.wslgconfig`.

### Memory and CPU

- 15:05:59 global OOM: swap 0 of 8 GB free, 26 Ghidra JVMs 16.8 GB, 17 `cc1plus`
  5.7 GB, 9 `claude` 2.9 GB. The JVMs ran in a slice their session had made for
  them, `user@1000.service/hs.slice/hs-emu.slice`, whose limit only throttled.
- `oom_score_adj`: agent sessions and their jobs 0, the user manager 100
  (`user@.service` ships `OOMScoreAdjust=100`), its services 200 (a user manager's
  default is its own value plus 100). The kernel killed `flakelab-state-sync`
  14:56:24, `flakelab-web` 14:57:40, `flakelab-tycswap-app` 14:58:50, then
  `user@1000.service` (`Result=signal`), which took every tmux session. The unit has
  no `Restart=` and stayed failed; `ssh-agent.service` then failed on its own stale
  socket (tycdev: the same since 2026-11-10).
- 14:16:52: one OOM-killed job (15.7 GB) ended its whole session scope
  (`DefaultOOMPolicy=stop`).
- `node_vmstat_oom_kill`: 18 kills in 3 days on GamerTyc, 0 on the EliteBook.
- No `memory.max` at any level. One session used 10.9 of 16 cores.
- Verified on the box by the reviewer of this spec: `OOMPolicy=continue` on a
  transient user scope keeps the scope and its shell through three OOM kills;
  `MemoryMax=75%` on a user slice is 0.75 × MemTotal and the memory and cpu
  controllers reach the user manager; inside a capped cgroup the kernel killed score
  800 before 500 before 0; an unprivileged process can raise its score and its
  children inherit it; `systemd-run --user --scope --slice=…` works from
  `/non-systemd`; `CPUWeight=20` on a user slice is applied.
- CPU weight, measured by a peer session: a fixed loop ran 33 M steps alone, 18 M
  beside 40 busy threads in its own cgroup and 27 M with those threads in a scope
  of their own.
- Anything a session starts with `systemd-run --user` leaves the session's cgroup,
  and a slice name with a dash nests below the slice named before the dash.
- Alerts exist and cover the WSL boxes: tycpve `saturation.yml`, "Kernel OOM Kill"
  and "Memory Pressure Sustained". No new rule is needed.

### Reference build

tycpve `gitlab-jobs.slice` (a5919cce, c0529875): CI jobs run in one slice with
`MemoryMax` sized as the VM's memory minus the measured need of its own services,
`MemorySwapMax=0` and `CPUWeight=20`, "so a burst of jobs is OOM-killed inside this
slice, never the VM's own services". The role asserts the budget fits the VM. PR 375
here applied the pattern to Docker and was reverted because Docker was not the load.
Two differences matter: CI jobs are short, agent sessions idle for hours and gain
from swap; and the runner's budget is a measured amount per host, which here becomes
a share with a per-box override.

## Goals

Each goal names the check that proves it. "Suite" is an offline `files/scripts/test-*`
or a `nix/checks.nix` evaluation, run by `nix flake check`; "doctor" is `flakelab
doctor` on a live box, which only reads; "pilot" is done once by hand and recorded in
the PR.

- G1. After a compositor crash WSLg comes back by itself. Suite: the wsl target
  evaluates without the `X0` mount unit unless `/tmp` is a tmpfs. Doctor: `X0` is no
  mountpoint. Pilot on GamerTyc after its next WSL start: `pkill weston` in the
  system distro, a new weston runs within 5 s, twice in a row.
- G2. A box configured `gui = "off"` starts without WSLg and without a failed unit.
  Suite: the `.wslconfig` edit sets `guiApplications=false` under `[wsl2]`, keeps
  every other byte and is idempotent. Doctor, after the next WSL start: `/mnt/wslg`
  is absent and no unit has failed.
- G3. A box configured `gui = "hardened"` runs WSLg without the clipboard bridge.
  Suite: the `.wslgconfig` edit. Pilot on the first such box: copy text on Windows
  twenty times in quick succession (the repro of #1407); weston's pid is unchanged.
- G4. A dead WSLg in a running VM is silenced with one command. Suite: `flakelab wslg
quiet --dry-run` names only `…\WSL\msrdc.exe` and refuses when more than one runs.
  Doctor: reports a dead compositor and names the command. Proven by hand on
  2026-11-11.
- G5. Under memory exhaustion the kernel kills workload first. Suite: evaluated
  units carry `OOMScoreAdjust=0` for `user@.service` and `DefaultOOMScoreAdjust=0`
  for the user manager; the wrapper sets 500; the tool-shell hook sets 800. Doctor:
  the user manager's live score.
- G6. What runs in the sessions' cgroups is bounded in memory and yields the CPU.
  Suite: `agents.slice` evaluates with the configured `MemoryMax`, `MemorySwapMax`
  and `CPUWeight`. Doctor: the live slice shows the same three values.
- G7. Agent sessions are in the slice however they start. Suite: `claude-sessions`
  starts and resumes every tool through the wrapper; the wrapper falls back to
  `choom` alone when no user manager answers; with `flakelab.agents = null` it
  execs the command unchanged. Doctor: lists agent processes outside `agents.slice`,
  and user slices outside it that hold processes.
- G8. A killed user manager and a stale agent socket repair themselves. Suite:
  `user@.service` evaluates with `Restart=on-failure`; `ssh-agent.service` removes
  its socket before starting. Pilot on tycdev, where the agent unit has been failed
  since 2026-11-10: after the update it starts; with no session running there,
  `systemctl kill -s KILL user@<uid>.service` and the manager answers again within
  10 s.
- G9. One mechanism, per-box values. Suite: the proxmox-vm target evaluates G5 to
  G8 and nothing of G1 to G4; no default names an absolute amount of memory or a CPU
  count; `flakelab.agents = null` and `flakelab.wsl.gui = null` evaluate to today's
  system plus G1 and the ssh-agent fix.

## Non-goals

- Limits on Docker containers (ruling "Revert"), on `nix-daemon` builds, and on
  work a session sends to another box. They sit outside the sessions' cgroups.
- systemd-oomd. The slice ceiling and the kill order decide who dies; the alerts
  already report it.
- A box-wide job runner. A repo's own limiter stays its own business, provided its
  slice nests below `agents.slice`.
- The VM's size (`memory`, `processors` in `.wslconfig`).
- A benchmark or load test of the limits. It would measure systemd and the kernel,
  not this repo, need an invented pass mark, and every run would add an OOM kill
  that fires the alert. The behaviour was measured once (Evidence); the doctor
  reads the live values.
- Fixing weston's clipboard code. The upstream issues carry the analysis.

## Anti-goals (failure even if it works)

- A limit that protects a runaway: no negative `oom_score_adj` anywhere, so a
  session started outside the wrapper still competes by size.
- Rewriting the operator's `.wslconfig`: only the named keys change, every other
  byte stays.
- Reaching outside the distro on a box that did not ask: with `gui = null` no
  update, switch or doctor run reads or writes a Windows file or starts a Windows
  process. `flakelab wslg quiet` is typed by a person and works on any box.
- Changing an adopter's box by default: with `flakelab.agents = null`, the default,
  neither the slice nor the kill order exists.
- Ending any `msrdc.exe` other than the one under the WSL install folder.
- `wsl --shutdown`, `wsl --terminate`, a dockerd restart or a user-manager restart
  from any script. The pilot of G8 is done by hand.
- A check on a live box that allocates memory, loads the CPU or kills a process.

## Design

### WSLg comes back (wsl target, unconditional)

The wsl target drops NixOS-WSL's `tmp-.X11\x2dunix-X0.mount` unless
`boot.tmp.useTmpfs` is set. WSL's own mount of the directory keeps `:0` reachable,
and the socket is a plain file again that a restarted weston can replace. This is
the change that ends the forced shutdowns on a box that keeps WSLg. Whether to tell
NixOS-WSL is the operator's call.

### WSLg profile (wsl target)

- `flakelab.wsl.gui`: `null` (default, nothing managed), `"off"` or `"hardened"`.
- `flakelab wsl-host [sync|status] [--dry-run]`, modelled on `flakelab tray`: `flakelab
update` runs `sync` after a switch, `flakelab doctor` reads `status`.
  - `off`: `[wsl2] guiApplications=false` in `%USERPROFILE%\.wslconfig`.
  - `hardened`: `guiApplications` removed; `[system-distro-env]
WESTON_RDP_CLIPBOARD=false` in `%USERPROFILE%\.wslgconfig`.
  - `status` compares the files with the option and the running VM with the files
    (`/mnt/wslg` present or absent); a difference of the second kind reads "takes
    effect at the next WSL start". After a start it reports a key that had no
    effect, with the WSL version, instead of gating on a version.
- `flakelab wslg quiet [--dry-run] [--all]`: ends `msrdc.exe` under the WSL install
  folder each time it reappears, for at most 60 s, until WSLGd logs that it no
  longer starts it. With more than one such process it stops unless `--all` is
  given, because every GUI distro's client matches. `flakelab doctor` detects the
  dead compositor from `stderr.log` and names the command. `known-issues.md`, "The
  terminal loses focus every half minute", is rewritten: cause, the mount, the
  command, the two profiles.

### Workload slice (every target)

- `flakelab.agents`: `null` (default) or a submodule: `memoryMax` (default `"75%"`
  of the RAM the box sees), `swapMax` (default `"50%"` of the swap, so half of it
  stays for the runtime) and `cpuWeight` (default 20, as the runner's job slice).
- Home Manager `systemd.user.slices.agents` with the three values. A user slice,
  because sessions are started by the user. Its weight ranks it against its
  siblings in the user manager (flakelab's services, tmux); a login shell sits
  outside the user manager and already competes as one group against all of it.
- `flakelab-agent-scope <command…>`: with `flakelab.agents = null` it execs the
  command. Otherwise: inside `agents.slice` already, it execs the command; else
  `systemd-run --user --scope --collect --slice=agents.slice -p OOMPolicy=continue
-- choom -n 500 -- <command…>`; with no user manager on the bus it execs `choom -n
500 -- <command…>` and says so on stderr.
- `claude-sessions` prefixes `TOOL_CMD` and the resume lines with the wrapper. The
  interactive shell gets `claude` and `codex` functions that call it.
- A shell that an agent tool starts (`CLAUDECODE` or `CODEX_THREAD_ID` set) raises
  itself to 800 in `.zshenv`, so what the agent runs dies before the agent.
- A job slice that a session makes for itself is named `agents-<name>.slice`. The
  dash nests it below `agents.slice`, where the ceiling holds for it too.
- Sizing: the doctor prints `memory.peak` of everything outside `agents.slice`. A box
  whose runtime needs more than the remaining share, or whose sessions need more
  than the slice, sets its own values in the overlay.

### Kill order (every target, with `flakelab.agents` set)

- `user@.service` drop-in: `OOMScoreAdjust=0`, `Restart=on-failure`, `RestartSec=2`.
- User manager `DefaultOOMScoreAdjust=0` (`systemd.user.extraConfig`).
- Agent tools 500, what they run 800. Nothing is set below 0.

### Self-repair (every target, unconditional)

- `ssh-agent.service`: `ExecStartPre` removes `%t/ssh-agent`.

## Rollout

1. PR A: the `X0` mount (G1), `wslg quiet` and the doctor's detection (G4),
   known-issues. Effective at each box's next WSL start; G1's pilot runs then.
2. PR B: workload slice, kill order, self-repair, wrapper, doctor (G5 to G9). The
   overlay enables it per box.
   - The kill order reaches a running box only when its user manager restarts,
     because the manager cannot lower the score PID 1 gave it. That is the next WSL
     start, which stays the operator's call; until then the services keep 200.
   - A session enters the slice when it is ended and resumed. `flakelab sessions
--open` does not resume a session that still runs.
   - Pilot order: tycdev (G8's pilot, and the box with the least memory), GamerTyc,
     then the EliteBook when a session next wakes there.
3. PR C: `wsl-host` and the `gui` option (G2, G3). The overlay sets the profile per
   box after the operator has chosen it with G1 proven.
4. The peer session that owns the emulator limiter is told once: name the slice
   `agents-<name>.slice`; its slot count stays its own choice.

## Open points

- G1 is proven only at a WSL start: the dead compositor on GamerTyc cannot be
  restarted in place. Until then the mount explanation rests on `mountinfo`, the
  weston source and the upstream report of a working restart.
- `swapMax = "50%"` and `memoryMax = "75%"` are untested on the EliteBook (VM
  12.5 GB: 9.4 GB for the slice, ten idle sessions hold about 3.2 GB) and on tycdev
  (4 GB: 3.0 GB for the slice, 1.0 GB for systemd, dockerd and `nix-daemon`). tycdev
  is the first pilot for that reason.
- Whether weston logs that the clipboard bridge is off is unknown; G3 is therefore a
  behaviour pilot, not a log check.
- A process can lower its own score again (`choom -n 0`). The order holds against
  accidents, not against intent.
