# Runtime protection Implementation Plan

**Goal:** the box's runtime outlives its agent workload, what dies comes back by
itself, and one mechanism fits every box.

**Spec:** `docs/superpowers/specs/2026-11-11-runtime-protection-design.md`. Goal ids
(G1 to G9) below are the spec's.

**Architecture:** three PRs. A makes WSLg recover from a crash and gives a command
for a dead one. B puts agent sessions into one user slice with a memory ceiling and
a low CPU weight and stops the user manager and its services from ranking above the
workload for the kernel's OOM killer. C lets a box own two keys of the Windows
user's WSL configuration.

**Tech stack:** NixOS and Home Manager modules, zsh scripts with offline suites
(`files/scripts/test-*`, run by `make test` and `nix flake check`), Python standard
library for the config edit, Windows PowerShell 5.1 reached through interop.

## Global Constraints

- No value below 0 for `oom_score_adj`, anywhere.
- No absolute memory amount or CPU count in any default.
- No benchmark or load test: every check that runs on a live box only reads. It
  allocates no memory, loads no CPU and kills no process.
- No script calls `wsl --shutdown`, `wsl --terminate`, restarts dockerd or restarts
  a user manager. The pilots of G1 and G8 are done once by hand.
- With `flakelab.wsl.gui = null` no update, switch or doctor run reads or writes a
  Windows file or starts a Windows process. `flakelab wslg quiet` is exempt: a
  person types it.
- With `flakelab.agents = null` the system differs from today's only by PR A and
  the ssh-agent fix.
- `.wslconfig` and `.wslgconfig` edits change only the named key; every other byte
  of the file is kept, including CRLF line ends and a missing final newline.
- Only `msrdc.exe` whose path ends in `\WSL\msrdc.exe` is ever ended.
- PowerShell receives its script through `-EncodedCommand`: on 2026-11-11 a script
  piped to `-Command -` ran nothing and printed nothing.
- Suites stay offline: stubs on `PATH` and fake trees, as `test-claude-sessions` and
  `test-nix-tycswap-tray` do.
- Each task writes its failing test first, then the code, then runs `make test` and
  `make lint`.
- No attribution trailers in commits or PR text.

## Review Focus

- The `X0` unit is dropped only when `/tmp` is not a tmpfs (`checks.targets`: absent
  by default, present with `boot.tmp.useTmpfs = true`).
- `wslg quiet` with two WSL clients running, and with a foreign `msrdc.exe`
  (`test-wslg-quiet: refuses two clients without --all`, `…: names only the WSL
client`).
- A session started with no user manager on the bus still gets score 500, a stderr
  note, and the tool starts (`test-agent-scope: falls back to choom without a user
manager`).
- A session already inside `agents.slice` is not nested into a second scope
  (`test-agent-scope: inside the slice it execs the command`).
- `flakelab.agents = null`: the wrapper execs the command and creates no slice
  (`test-agent-scope: disabled, it execs the command`; `checks.runtime-protection`:
  no slice, no drop-in).
- The tool-shell hook raises only a shell that carries the agent marker, and never
  lowers a higher score (`test-zsh-agent-score`).
- `.wslconfig` with CRLF, a comment between section and key, a `[WSL2]` header in
  another case, and a key already set to the wanted value (`test-wslconf: keeps
foreign lines byte for byte`, `…: idempotent`).
- The doctor's runtime section starts no process on the box besides reading
  `/proc`, the cgroup tree and `systemctl show` (`test-nix-doctor`: a stub
  `systemd-run` on `PATH` is never called).

---

## PR A: WSLg recovers (G1, G4)

### Task A1: the `X0` mount

**Files:** `nix/targets/wsl.nix`, `nix/checks.nix`, `files/scripts/nix-doctor`,
`files/scripts/test-nix-doctor`.

**Interface:** the wsl target disables `tmp-.X11\x2dunix-X0.mount` unless
`config.boot.tmp.useTmpfs`. The doctor's WSL section fails when `X0` is a mountpoint
while `/tmp` is not a tmpfs, and says that the next WSL start clears it.

**Failing test first:** `checks.targets` asserts the unit's absence by default and
its presence with `boot.tmp.useTmpfs = true`; the doctor suite feeds a `mountinfo`
with and without the `X0` line.

### Task A2: `flakelab wslg quiet`

**Files:** `files/scripts/wslg-quiet`, `files/scripts/wslg-quiet.ps1`,
`files/scripts/test-wslg-quiet`, `files/scripts/flakelab` (router), `nix/cli.nix`,
`nix/scripts.nix`, `nix/checks.nix`, `files/scripts/nix-doctor`.

**Interface:** `flakelab wslg quiet [--dry-run] [--all]`. Ends the WSL client each
time it reappears for at most 60 s, then reads `/mnt/wslg/stderr.log` for WSLGd's
"not starting it again" line for msrdc. Exit 0 when the line is there, 1 otherwise,
2 on more than one client without `--all`. The doctor detects a dead compositor
(weston's cap line present and an msrdc relaunch in the last two minutes) and names
the command.

**Failing tests first:** `--dry-run` with a stub PowerShell listing one WSL client
and one foreign `msrdc.exe`; two WSL clients; the log parser on the 2026-11-11
lines (`Run:121` for weston, then for msrdc).

### Task A3: documents

**Files:** `known-issues.md` ("The terminal loses focus every half minute"
rewritten: the clipboard crash, the mount that kept it down, `flakelab wslg quiet`),
`ARCHITECTURE.md` (Targets: the wsl target drops the unit), `CHANGELOG.md`.

### Task A4: rollout

- `flakelab update` on GamerTyc, tycdev (no effect there) and, when a session wakes
  on it, the EliteBook.
- **Operator-only:** each box's next WSL start, at a time of their choosing.
- After GamerTyc's next start, before any profile is set: `flakelab doctor` (`X0` no
  mountpoint), then G1's pilot by hand: `pkill weston` through `wsl.exe --system`,
  a new weston within 5 s, twice. The result goes into the PR and decides the WSLg
  profile question put to the operator.

---

## PR B: workload slice, kill order, self-repair (G5 to G9)

### Task B1: options, slice, kill order, self-repair

**Files:** `nix/options.nix`, `nix/configuration.nix`, `nix/home/agents.nix` (new,
imported from `nix/home/default.nix`), `nix/home/git-ssh.nix`, `nix/checks.nix`.

**Interfaces:**

- `flakelab.agents`: `nullOr (submodule { memoryMax; swapMax; cpuWeight; })`,
  default `null`. `memoryMax` and `swapMax` are `strMatching
"([1-9][0-9]?|100)%"`, defaults `"75%"` and `"50%"`; `cpuWeight` `ints.between 1
10000`, default 20.
- User slice `agents.slice`: `MemoryMax`, `MemorySwapMax`, `CPUWeight`.
- With `agents` set: drop-in for `user@.service` (`OOMScoreAdjust=0`,
  `Restart=on-failure`, `RestartSec=2`) and `DefaultOOMScoreAdjust=0` in
  `systemd.user.extraConfig`.
- Always: `ssh-agent.service` `ExecStartPre` removing `%t/ssh-agent`.

**Failing test first:** a `runtime-protection` check in `nix/checks.nix` evaluating
both targets with `agents` set and with `null`.

### Task B2: `flakelab-agent-scope`

**Files:** `files/scripts/agent-scope`, `files/scripts/test-agent-scope`,
`nix/scripts.nix`, `nix/checks.nix`, `nix/home/packages.nix` (on `PATH`).

**Interface:** `flakelab-agent-scope <command> [args…]`; exit status is the
command's. `FLAKELAB_AGENTS_SLICE`, set by the nix wrapper only when `agents` is
configured, names the slice; unset means `exec` the command. Otherwise, in order:
own cgroup path contains `/agents.slice/` → `exec`; `systemctl --user
show-environment` succeeds → `exec systemd-run --user --scope --collect --quiet
--slice=agents.slice -p OOMPolicy=continue -- choom -n 500 -- <command…>`; else
`exec choom -n 500 -- <command…>` after one stderr line.

**Failing tests first:** the four branches with stub `systemd-run`, `systemctl`,
`choom` and a cgroup path taken from an environment variable; arguments with spaces
arrive unchanged; no command given exits 2.

### Task B3: sessions and tool shells

**Files:** `files/scripts/claude-sessions` (`TOOL_CMD`, `resume_args`),
`files/scripts/test-claude-sessions`, `nix/home/zsh.nix`,
`files/scripts/test-zsh-agent-score` (new).

**Interface:** every start and resume line begins with `flakelab-agent-scope`. The
interactive shell defines `claude` and `codex` functions that call it with
`command`. `.zshenv`: when `CLAUDECODE` or `CODEX_THREAD_ID` is set and the shell's
`oom_score_adj` is below 800, it writes 800 to `/proc/$$/oom_score_adj`; a failed
write is silent.

**Failing tests first:** `--start`, `--open` and `--resume` output carry the wrapper
for both tools and for a profile-prefixed resume; the hook with the marker, without
it, and with a score already above 800.

### Task B4: doctor

**Files:** `files/scripts/nix-doctor`, `files/scripts/test-nix-doctor`.

**Interface:** a "runtime protection" section, present only with `agents` set: the
live slice's three properties against the configuration; `oom_score_adj` of the user
manager, with "takes effect when the user manager next starts" while it still reads
100; every `claude` and `codex` process whose cgroup is outside `agents.slice`, with
its pid; every user slice outside `agents.slice` that holds processes and is not
`app.slice`, `session.slice` or `background.slice`, with the naming rule; and
`memory.peak` of `system.slice` and of the user manager's tree outside
`agents.slice`, for sizing.

**Failing tests first:** fake `/proc` and cgroup trees for a session inside the
slice, one in `/non-systemd`, a user manager at 100, and a foreign `hs.slice`.

### Task B5: documents

**Files:** `ARCHITECTURE.md` (one section, "Workload and runtime", with the naming
rule for job slices), `known-issues.md` (a session outside the slice; the kill order
before the user manager restarts), `CHANGELOG.md`,
`files/config/claude/target-wsl.md` (one line: a job slice is named
`agents-<name>.slice`).

### Task B6: pilot and rollout

- tycdev first. Check no agent session runs there, `ssh tycdev flakelab update` with
  `agents` set in its overlay entry, then G8's pilot by hand (the agent unit starts;
  `sudo systemctl kill -s KILL user@<uid>.service`, the manager answers within
  10 s), then `ssh tycdev flakelab doctor`. Read the printed peaks; if 25 % of its
  RAM is less than the runtime's peak, lower its `memoryMax` in the same rollout.
- GamerTyc: `flakelab update`, `flakelab doctor`. Each session enters the slice when
  it is ended and resumed. **Operator-only:** the moment for that, and the next WSL
  start, at which the kill order takes effect.
- EliteBook: when a session next wakes there.
- Tell the peer session that owns the emulator limiter the outcome, once.

---

## PR C: WSLg profile (G2, G3)

### Task C1: the config edit

**Files:** `files/scripts/lib/wslconf.py`, `files/scripts/lib/test-wslconf.py`.

**Interface:** `set_key(text, section, key, value) -> text` and `remove_key(text,
section, key) -> text`; section and key match without regard to case; an absent
section is appended; the input's line ends are kept.

**Failing tests first:** the cases under Review Focus, plus an empty file and a file
that is only `[wsl2]`.

### Task C2: `flakelab wsl-host`

**Files:** `files/scripts/nix-wsl-host`, `files/scripts/test-nix-wsl-host`,
`nix/options.nix` (`flakelab.wsl.gui`), `nix/scripts.nix`, `nix/cli.nix`,
`files/scripts/flakelab`, `files/scripts/nix-update` (after `tray sync`),
`files/scripts/nix-doctor`, `nix/checks.nix`.

**Interface:** `flakelab wsl-host [sync|status] [--dry-run]`, shaped like `flakelab
tray`. `status` exits 1 when `sync` has work; prints "takes effect at the next WSL
start" when the files are right and the running VM is not; after a start with `off`
and `/mnt/wslg` still present it names the key that had no effect and the WSL
version.

**Failing tests first:** each `gui` value against a fake `%USERPROFILE%`; `null`
starts no stub and touches nothing; `--dry-run` writes nothing.

### Task C3: documents and rollout

- `known-issues.md` (the two profiles), `ARCHITECTURE.md` (what the wsl target owns
  on the Windows side), `CHANGELOG.md`.
- **Operator-only:** the profile per box, chosen with G1's result in hand, and each
  box's next WSL start.
- After that start: `flakelab doctor` for G2; G3's pilot on the first `hardened` box.
