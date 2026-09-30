# Known Issues

## WSL mount guard fails to start on NixOS (worked around)

WSL generates `wsl-mnt-guard.service` with `ExecStart=/bin/true`. That path
does not exist on NixOS, so the guard fails with `203/EXEC` and
`flakelab update` exits 4 even after activating the new generation.

The WSL target supplies a systemd drop-in that resets only `ExecStart` to
the Nix-store `true` executable. WSL still owns the mount condition,
ordering and shutdown action, including its configured automount root.
An already-active guard is not restarted during a switch: its `ExecStop`
changes mount propagation and belongs at shutdown. The Proxmox target
does not receive this drop-in.

After updating, `systemctl status wsl-mnt-guard.service` should show
`active (exited)` and `flakelab update` should finish successfully. No
WSL shutdown is needed to apply the workaround. The generated unit comes
from [WSL's init](https://github.com/microsoft/WSL/blob/master/src/linux/init/init.cpp).

## WSL interop break when provisioning the NixOS distro (unfixed on stable through 2.7.12)

**Provisioning wipes host interop.** A full `build-dev-wsl-nix` run on **WSL
2.7.10 / kernel 6.18** (imports a NixOS-WSL distro and applies the flake)
completes `nixos-rebuild switch` **successfully**, and the host distro's
`WSLInterop` handler is **gone** from `/proc/sys/fs/binfmt_misc/` afterward —
`.exe` calls fail with `exec format error`. Recovery is `wsl --shutdown`.

**Upstream status (corrected 2026-08-21).** PR
[#40621](https://github.com/microsoft/WSL/pull/40621) (closing
[#13885](https://github.com/microsoft/WSL/issues/13885)) bind-mounts
`/proc/sys/fs/binfmt_misc/status` read-only, re-registers `WSLInterop` with
the `F` flag from `mini_init`, and ships a regression test
(`BinfmtSurvivesDistroTermination`) that matches our repro exactly. But it has
**never shipped to a stable release**: it landed on `master` and reached only
the **pre-release channel, from 2.9.3 on**. `release/2.7` carries no binfmt
commits through 2.7.12 (2026-08-18) — the widely repeated "fixed in 2.7.x"
claims (including the maintainer's closing comment on #13885) are wrong. Every
stable-channel install therefore has **no protection at all**, and the
2.7.10/2.7.11 observations below are the original, entirely-unfixed bug — an
earlier revision of this section claimed a residual "per-entry" gap in the
fix; that misread a compatibility note in the PR body.

**Retirement path.** On a throwaway host: `wsl.exe --update --pre-release`
(≥ 2.9.3), re-run the repro (provision the systemd NixOS distro, terminate
it), then check a peer distro still has
`/proc/sys/fs/binfmt_misc/WSLInterop` **with the `F` flag** (flag loss is the
subtler regression). Field report
[#41016](https://github.com/microsoft/WSL/issues/41016) suggests the fix
holds. If it does, this hazard downgrades to "stable channel only". Known
side effect on ≥ 2.9.3: every systemd distro's `systemd-binfmt.service` fails
benignly at boot with `Read-only file system`
([#41226](https://github.com/microsoft/WSL/issues/41226)); `wsl.conf`
`[boot] protectBinfmt=false` is the escape hatch if the flush failure ever
matters (e.g. `boot.binfmt` qemu-user setups).

**Mechanism.** `binfmt_misc` is a single **kernel-global registry shared by every
distro** in the WSL2 VM (confirmed by the `wsl-interop-bug` repro: `systemd=true`
→ handler GONE after terminate; `systemd=false` → PRESENT). The Ansible-provisioned
predecessor distro dodged it by running its test distro with `systemd=false`;
**NixOS-WSL requires systemd**, so that escape hatch is closed here — there is no
known way to provision the NixOS distro from a sibling without wiping host interop.

**Symptom:** `exec format error` calling any Windows `.exe` (e.g. `wsl.exe`,
`powershell.exe`) from the host distro after building/running the NixOS distro.

**Practical guidance — treat every provisioning run as costing at least one
interop wipe:**

- Run `build-dev-wsl-nix` / `test-provision-nix` **only from an expendable
  session** you can afford to `wsl --shutdown` — never from a session doing other
  work. Both are host-side and are on PATH: their wrappers export
  `FLAKELAB_REPO_ROOT` from `repoPath`, so neither derives its repo root from its
  own location any more (`${0:A:h:h:h}` stays as the fallback for a plain
  checkout, where `files/scripts/<name>` still works). Automation/agents must
  **not** run these from a session that needs interop, and must **not** run
  `wsl --shutdown` themselves.
- `build-dev-wsl-nix` still avoids `wsl --terminate` (so it does not add a
  _second_ wipe), and derives the expected user/locale from
  `nix/users/default.nix` for its checks.
- `test-provision-nix` hard-fails its precheck when interop is already broken.
- **Recovery:** `wsl --shutdown` from a Windows terminal, then re-enter the host
  distro (`/init` re-registers the handler on VM boot). The heal holds only until
  the next stop of a systemd distro in the VM wipes the handler again, so it goes
  after a run's last `wsl --terminate`, never before it, as `setup-wsl-nix.ps1`
  orders it. The durable fix is upstream's
  [#40621](https://github.com/microsoft/WSL/pull/40621), which only the
  pre-release channel carries (see the retirement path above).
- **There is no in-distro repair — do not attempt one.** Registering the handler
  by hand puts unmanaged state into a VM-global registry that WSL rewrites on its
  own schedule; `wsl --shutdown` re-creates the real entry, at the price of
  killing every WSL session in the VM, which is why it is the recovery step and
  not a routine one, and never an agent step.

### The wipe is not bounded to a rebuild — trigger unidentified

The "one wipe per provisioning run" framing above is the floor, not the scope.
Observed 2026-08-12: the handler went away with **no `nixos-rebuild` and no
distro termination in between** — a provisioning run's own interop check
reported OK, and `.exe` calls were dead minutes later with nothing in the
journal for that window but a user `systemd-tmpfiles` cleanup.

Two candidate mechanisms are **ruled out for this distro**:

- **A sibling systemd distro shutting down.** A stock Ubuntu WSL distro runs
  **without** systemd unless `[boot] systemd=true` is set: measured on one,
  `/proc/1/comm` is its own init rather than systemd. Unless another systemd
  distro has been imported, the flakelab distro is the only one in the VM.
- **`systemd-binfmt.service` flushing inherited registrations**
  ([systemd#28126](https://github.com/systemd/systemd/issues/28126),
  [ubuntu/WSL#334](https://github.com/ubuntu/WSL/issues/334)). This flake declares
  no `boot.binfmt`, so that unit is not in the closure at all —
  `systemctl status systemd-binfmt.service` returns "could not be found" and
  `/etc/binfmt.d/nixos.conf` is empty, so it never runs here.

The trigger is therefore **unidentified**. Do not read a cause into the two
exclusions; they only narrow the search.

**Untested candidate, not a fix:** NixOS-WSL's `wsl.interop.register` option
(default `false`) declares the handler through `boot.binfmt.registrations`, which
would make it system state this flake owns rather than something inherited.
NixOS-WSL's own release notes warn that enabling it "may lead to WSLInterop
breaking in other WSL distributions as a side effect", so it trades one VM-global
failure mode for another and has not been tried here.

Upstream: [microsoft/WSL#13885](https://github.com/microsoft/WSL/issues/13885)
(closed by [#40621](https://github.com/microsoft/WSL/pull/40621) for the
distro-**termination** wipe; the wipe documented here persists on 2.7.11.0, and
the observation above shows it is not tied to a rebuild either). The issue still
open is [#8203](https://github.com/microsoft/WSL/issues/8203) — `binfmt_misc`
namespacing, which would isolate the registry per distro and close the whole
class rather than one trigger. That is what `nix-doctor` links when it reports a
missing handler.

---

## No user manager: `user@<uid>.service` fails with `Permission denied`

### Symptom

On some starts of a distro and not others, no user unit runs. `ssh-add` prints
`Error connecting to agent: No such file or directory`, `systemctl --user`
cannot connect to the user scope bus, and the journal has, per login:

```text
systemd[…]: Failed to create /<cgroup>/user.slice/user-1000.slice/user@1000.service/init.scope control group: Permission denied
systemd[…]: Failed to allocate manager object: Permission denied
```

`cat /proc/1/cgroup` reads `0::/<cgroup>/init.scope`, not `0::/init.scope`, and
`ls -ld /sys/fs/cgroup/<cgroup>` shows a directory only root may enter.

A `/proc/1/comm` other than `systemd` is a different case that loses the same
user units: WSL started the distro with its own init as PID 1, which it does unless
`/etc/wsl.conf` carries `[boot] systemd=true` (NixOS-WSL writes it from
`wsl.wslConf.boot.systemd`), so no unit runs at all. WSL reads the file when the
distro starts: restore the setting, then `wsl --shutdown` from a Windows terminal.
`flakelab doctor`'s "systemd cgroup" section fails on either and names PID 1's
cgroup.

### Root Cause

Every distro in the WSL VM shares one cgroup hierarchy, and WSL starts a distro in
the cgroup of the process that launches it. A program running inside the VM can
move that launcher into a cgroup of its own; seen with an endpoint-security agent,
whose 0700 cgroup at the top of the tree then holds the agent and every distro
started once it is up. systemd roots its whole tree in the cgroup it starts in, so
it builds `user.slice` below that directory, and a user manager, which runs as
the user and must reach its own cgroup through every directory above it, cannot.
A distro that started first, typically the one that booted the VM, stays at the
top, and a running distro is never moved: whichever distro starts first decides
the boot, which is why the same box works one day and not the next.

### Fix (applied)

`flakelab-wsl-init-cgroup` (files/scripts/wsl-init-cgroup) runs in the wsl
target's activation, which the NixOS-WSL init shim runs before it execs systemd.
When PID 1's cgroup, or one above it, denies other users search permission, it
moves the distro's processes into `/flakelab-<id>/init.scope`, a top-level cgroup
of its own named after the machine id, and systemd roots its tree there. Nothing else in the other
cgroup is touched: a process outside the distro's PID namespace cannot even be
named from inside it. The outcome is in `/run/flakelab/init-cgroup` and in
`flakelab doctor`'s "systemd cgroup" section, which also names a move the kernel
refused.

A distro caught before it had this fix: `flakelab update`, then `wsl --shutdown`
from a Windows terminal; its next start is moved.

### What Does NOT Work

- **Starting this distro first, or making it the default.** It holds only until
  something else in the VM starts first.
- **Changing the other cgroup's mode.** It belongs to the program that made it,
  not to this flake.

---

## Terminal Rendering Corruption (Null Bytes from wsl.exe)

### Symptom

After `test-provision` calls `wsl.exe` (directly or via `powershell.exe`), subsequent zsh `print` calls produce output but the terminal stops rendering it. Output is buffered invisibly — pressing Enter or Ctrl+C flushes the buffered content. The script is NOT hung; it's running and producing output that the terminal doesn't display.

### Root Cause

`wsl.exe` emits UTF-16LE null bytes (`\0`) in its output stream. These null bytes corrupt the terminal's rendering layer, causing it to stop displaying new output. Diagnostics confirmed this is **not** a console mode flag change (`SetConsoleMode` flags remain unchanged) — it's the null bytes themselves that break rendering.

### Fix (applied)

**build-dev-wsl-nix / test-provision-nix:**

1. **`setsid -w`** wraps the long `wsl.exe` calls that redirect to a log file (the `nixos-rebuild` step in `build-dev-wsl-nix`). Creates a new session with no controlling terminal — null bytes are written to the log file and never reach the host terminal.
2. **`tail -f` with `< /dev/null`** runs in the background reading from the log file (not a pipe). Provides real-time output. `< /dev/null` prevents stdin inheritance that could reintroduce pipe hangs.
3. **`tr -d '\0\r'`** wherever `wsl.exe` output must go directly to the terminal: the `wsl_clean()` helper in both scripts, plus temp file + `tr` for the `--import` output. Strips null bytes and carriage returns before display.

**setup-wsl-nix.ps1:**

Strips the null bytes in-band (``-replace "`0", ''`` on captured `wsl.exe` output) and sends the final `wsl.exe --terminate` through `Out-Null`, so no UTF-16LE null bytes flow through PowerShell's stdout.

### What Does NOT Work

- **`stty sane`** — addresses terminal line discipline (echo, raw/cooked), not the rendering corruption caused by null bytes
- **`< /dev/null` alone** — `wsl.exe` accesses the console directly, bypassing stdin redirection
- **Pipe-based streaming** (`| tee`, `| Tee-Object`) — background processes (ssh-agent, dockerd) inherit pipe FDs and keep them open indefinitely

---

## Non-TTY Hangs (SSH, Prompts, Pipes)

### Symptom

`test-provision` hangs indefinitely during re-runs (idempotency, toggle, defaults) or Ansible tasks that touch SSH/git. No error, no output — the process blocks forever.

### Root Cause

Any operation that expects interactive input hangs when run without a TTY. The initial provisioning (`setup-wsl.ps1`) starts a temporary `ssh-agent` and loads the key via `SSH_ASKPASS` (no TTY needed). That agent **dies when the script exits**. All subsequent runs (idempotency, toggle, defaults) have no agent and no TTY for passphrase prompts.

### Known Trigger Patterns

| Pattern                                   | Why it hangs                                                          |
| ----------------------------------------- | --------------------------------------------------------------------- |
| `zsh -ilc 'nix-update'` in test           | OMZ ssh-agent plugin calls `ssh-add` → passphrase prompt → no TTY     |
| `git+ssh://` in Ansible (uv, git archive) | SSH needs key auth → no agent, no TTY for passphrase                  |
| `\| tee` / `\| Tee-Object` with `wsl.exe` | ssh-agent inherits pipe FDs, keeps pipe open after main process exits |
| `read -q` in aliases                      | Blocks on stdin when not a terminal                                   |
| `sudo` with extra args not in sudoers     | Password prompt → no TTY                                              |
| `ssh -T git@host` checks                  | SSH connection test prompts for passphrase                            |
| CLI tools (claude, make) with prompts     | Interactive prompts in non-tty                                        |

### Fix Patterns

**For in-distro checks and re-runs:** invoke with non-interactive `zsh -lc` (as `test-provision-nix` does throughout), never `zsh -ilc` — interactive shells load OMZ, whose ssh-agent plugin blocks on a passphrase prompt without a TTY.

**For steps that reach `git+ssh://`** (plugin clones in `home.activation`, `nix-clone-repos`): keep them idempotent — guard on the artifact already existing so re-runs never touch SSH at all.

**Do NOT use `GIT_SSH_COMMAND` with `-i` for passphrase-protected keys as if it
replaced the agent** — it bypasses the agent and forces SSH to read the raw key
file. Without a TTY it cannot prompt for the passphrase, so it does not hang: it
fails outright with `Permission denied (publickey)`. The activation steps in
`nix/home/kiro.nix` and `nix/home/claude.nix` that clone over SSH pass `-i`
**and** point at the agent
(`sshAgentPreamble`) for exactly that reason — the `-i` alone authenticates
nothing.

**For `home.activation` steps that reach SSH:** activation runs from the
`home-manager-<user>.service` unit, which has no `SSH_AUTH_SOCK`, and the
provisioned key is passphrase-encrypted — so those steps cannot authenticate on a
fresh distro no matter how they are written. `sshAgentPreamble` therefore points
`SSH_AUTH_SOCK` at `/run/user/<uid>/ssh-agent` (reachable from the unit: same
UID, and `/run/user/<uid>` is 0700 and user-owned) and sets `_sshReady` from
whether `ssh-add -l` finds a key there. When it does not, the step's failure is
**deferred** (`sshDefer` → `flakelab-defer` → `activation-deferred`) rather than
fatal: reported loudly, but it must not fail the rebuild — the alternative is a
distro that cannot be rebuilt offline or before its first interactive login. The
health check treats a post-condition that an already-recorded deferral explains
as `[DEFER]`, not `[FAIL]`. What fills the agent is the TTY-gated `ssh-add` hook
in `programs.zsh.initContent`, so the first `nix-update` after an interactive
login completes the deferred steps.

**For interactive prompts:** guard with `[[ -t 0 ]]` before any `read` or interactive command.

**For pipe hangs:** redirect to file instead of piping `wsl.exe` output. Background processes (ssh-agent, dockerd) inherit pipe FDs and keep them open.

### Why This Keeps Regressing

This bug class has been fixed and re-introduced **14 times**. The pattern is always:

1. A fix avoids the non-tty path (e.g., `zsh -c` instead of `zsh -ilc`, or `GIT_SSH_COMMAND`)
2. A later commit restores the interactive path because "the agent handles it" or "to mirror the real workflow"
3. The test hangs again

**The agent does NOT handle it in test distros.** Never assume an SSH agent is available in provisioning steps or test re-runs. Keep SSH-touching steps idempotent (skip when the artifact already exists). `services.ssh-agent` starts an agent but loads no key, and `addKeysToAgent` does not change that — `ssh_config(5)` adds a key only when ssh loads it from a file mid-connection, which for a passphrase-protected key needs a TTY prompt first. What actually fills the agent is the TTY-gated `ssh-add` hook in `programs.zsh.initContent`, so a populated agent exists only after an interactive login.

## Known limitations

Not bugs — things the flake does not do yet:

- Sudoers narrowing has no Nix counterpart yet; the provisioned user keeps
  wheel-wide sudo.
- `core.fileMode=false` is not set on a flake clone living on `/mnt/c`.
- This repo's own pre-commit hooks are installed only by `make install-hooks`:
  `activate-hooks` scans `~/git` and never reaches a checkout on the Windows
  mount, so gitleaks does not gate commits here automatically.
- `proxmox-vm`: wheel-wide sudo as on `wsl` — the sudoers-narrowing limitation
  above applies here too. `vzdump` fs-freeze is refused on purpose (the
  qemu-guest-agent unit drops that capability), so a Proxmox backup of this
  target is crash-consistent, not application-consistent.

## Upgrading a box provisioned before the `wslnix` → `flakelab` rename

The rename moved four on-disk names, and none of them migrate automatically.
Each is quiet when it is wrong, so a stale one looks like a healthy box.

- **State directory** — `~/.local/state/wslnix/` became
  `~/.local/state/flakelab/` (`nix/home/default.nix` `stateDir`, read by
  `nix/home/health.nix` and the doctor). Activation `mkdir -p`s the new path,
  so a `skip-healthcheck` marker or an `activation-failures` log left in the
  old one is silently ignored rather than reported. Move the directory by
  hand, or re-`touch` the marker under the new path.
- **Defer unit** — `wslnix-defer` became `flakelab-defer`. The old unit
  lingers until the box re-switches, while the doctor looks for the new name.
- **Distro registration** — a distro registered as `wslnix` (or `NixOS` on the
  oldest generation) keeps that name. A default `provision` re-run would
  import a SECOND distro rather than update it, so pass `-DistroName` with the
  name `wsl -l -v` reports.
- **Option namespace** — `options.wslnix.*` became `options.flakelab.*`. This
  bites only an overlay that sets values through the namespace directly
  (`modules = [ { wslnix.username = …; } ]`); an overlay going through
  `lib.mkSystem` with unprefixed `userData` keys is unaffected.
