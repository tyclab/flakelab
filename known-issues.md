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

## WSL interop during provisioning

On WSL 2.7.10 and 2.7.11, provisioning or stopping a systemd distro could remove
`WSLInterop` from the VM-wide `binfmt_misc` registry. Windows executables then
failed with `exec format error`; recovery required `wsl --shutdown` from Windows.
Those observations describe the old releases, not a verified failure on WSL 3.

Stable [WSL 3.0.3](https://github.com/microsoft/WSL/releases/tag/3.0.3) includes
[the registry protection](https://github.com/microsoft/WSL/pull/40621) first
shipped in the 2.9.3 prerelease. Its
[writable shadow status file](https://github.com/microsoft/WSL/pull/41808) also
fixes the earlier `systemd-binfmt` read-only startup failure: writes succeed
without flushing the shared registry, and WSL restores its interpreter entry.
There is no need to disable `protectBinfmt` for that old failure.

On 2026-10-25 `flakelab test-provision` imported, verified and unregistered a
sibling distro on WSL 3.0.3 from a running flakelab session; the `WSLInterop`
entry kept its `PF` flags and Windows executables answered throughout. Keep
provisioning tests in a disposable session anyway: `flakelab build-distro` and
`flakelab test-provision` perform distro lifecycle operations, and
`wsl --shutdown` still ends every active WSL session.

A missing handler and a stale `WSL_INTEROP` socket are different failures.
Check the handler and whether the inherited socket exists before assuming that
Windows integration is unavailable. A successful command through a live socket
proves interop works; it does not prove an authenticated browser connection.
Do not manually replace WSL's VM-wide handler or disable its protection.

The [mount-guard workaround](#wsl-mount-guard-fails-to-start-on-nixos-worked-around)
remains necessary on 3.0.3: WSL still generates `ExecStart=/bin/true`, which this
NixOS installation does not provide.

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

**`flakelab build-distro` / `flakelab test-provision`:**

1. **`setsid -w`** wraps the long `wsl.exe` calls that redirect to a log file (the `nixos-rebuild` step in `build-distro`). Creates a new session with no controlling terminal — null bytes are written to the log file and never reach the host terminal.
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
| `zsh -ilc 'flakelab update'` in test      | OMZ ssh-agent plugin calls `ssh-add` → passphrase prompt → no TTY     |
| `git+ssh://` in Ansible (uv, git archive) | SSH needs key auth → no agent, no TTY for passphrase                  |
| `\| tee` / `\| Tee-Object` with `wsl.exe` | ssh-agent inherits pipe FDs, keeps pipe open after main process exits |
| `read -q` in aliases                      | Blocks on stdin when not a terminal                                   |
| `sudo` with extra args not in sudoers     | Password prompt → no TTY                                              |
| `ssh -T git@host` checks                  | SSH connection test prompts for passphrase                            |
| CLI tools (claude, make) with prompts     | Interactive prompts in non-tty                                        |

### Fix Patterns

**For in-distro checks and re-runs:** invoke with non-interactive `zsh -lc` (as `flakelab test-provision` does throughout), never `zsh -ilc` — interactive shells load OMZ, whose ssh-agent plugin blocks on a passphrase prompt without a TTY.

**For steps that reach `git+ssh://`** (plugin clones in `home.activation`, `flakelab clone`): keep them idempotent — guard on the artifact already existing so re-runs never touch SSH at all.

**Do NOT use `GIT_SSH_COMMAND` with `-i` for passphrase-protected keys as if it
replaced the agent** — it bypasses the agent and forces SSH to read the raw key
file. Without a TTY it cannot prompt for the passphrase, so it does not hang: it
fails outright with `Permission denied (publickey)`. The activation steps in
`nix/home/claude.nix` that clone over SSH pass `-i`
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
in `programs.zsh.initContent`, so the first `flakelab update` after an interactive
login completes the deferred steps.

**For interactive prompts:** guard with `[[ -t 0 ]]` before any `read` or interactive command.

**For pipe hangs:** redirect to file instead of piping `wsl.exe` output. Background processes (ssh-agent, dockerd) inherit pipe FDs and keep them open.

### Why This Keeps Regressing

This bug class has been fixed and re-introduced **14 times**. The pattern is always:

1. A fix avoids the non-tty path (e.g., `zsh -c` instead of `zsh -ilc`, or `GIT_SSH_COMMAND`)
2. A later commit restores the interactive path because "the agent handles it" or "to mirror the real workflow"
3. The test hangs again

**The agent does NOT handle it in test distros.** Never assume an SSH agent is available in provisioning steps or test re-runs. Keep SSH-touching steps idempotent (skip when the artifact already exists). `services.ssh-agent` starts an agent but loads no key, and `addKeysToAgent` does not change that — `ssh_config(5)` adds a key only when ssh loads it from a file mid-connection, which for a passphrase-protected key needs a TTY prompt first. What actually fills the agent is the TTY-gated `ssh-add` hook in `programs.zsh.initContent`, so a populated agent exists only after an interactive login.

## The WSL disk image grows until the operator compacts it

The distro lives in a dynamic `ext4.vhdx` with a 1 TB virtual size. The file
grows whenever the VM touches a part of that range it never wrote before and
never shrinks by itself, so builds, Docker layers and scratch files inflate it
far past the data inside: on 2026-10-25 TycbookElite's image was 165 GB for
122 GB of files, and its 277 GB `D:` fell from 27 GiB free to 0.4 GiB in a
week while `df` inside the VM showed 13 % used. A full host drive fails writes
inside every session on the box.

The image is not sparse, and `wsl --manage <distro> --set-sparse true` is not
the fix: WSL 2.5.6 put it behind `--allow-unsafe` because sparse images
corrupted data ([microsoft/WSL#10609](https://github.com/microsoft/WSL/issues/10609),
still open), WSL 3.0.2 only re-enabled it as experimental without a fix, and a
sparse image on a drive that ran out of space came back unreadable
([microsoft/WSL#41837](https://github.com/microsoft/WSL/issues/41837)).

What runs inside the VM, by an agent or the weekly timers:
`sudo systemctl start nix-gc.service docker-prune.service` and the
`flakelab-prune` user timer free the Nix store, Docker and the tool caches.
`docker-prune` keeps whatever is younger than a week (`until=168h`), so images
built or pulled in the last week survive it (10 GB on 2026-10-25); with no
container running, `docker image prune -af` takes them too. `sudo fstrim -v /`
then marks the freed blocks so the compaction can drop them.

The compaction itself is the operator's, with the distro stopped: `wsl --shutdown`
ends every session, so `flakelab sessions --save` first and `--open`
afterwards. `Optimize-VHD` needs the Hyper-V PowerShell module; without it
`diskpart` does the same (`select vdisk file=<path>`, `attach vdisk readonly`,
`compact vdisk`, `detach vdisk`). After the trim, that took TycbookElite's
image from 164 GB to 101 GB for 72 GB of files on 2026-10-26 and gave `D:`
64 GB back. The Grafana rule "PC Drive Low" (tycpve) pages when a PC drive
drops under 20 GiB free.

## Slow session start or dead interop: no memory block for the vsock ring

A WSL session that takes about ten seconds to start, or Windows executables
failing with `exec format error` or `accept4 failed 110` while the `WSLInterop`
handler is registered, can mean the kernel found no free order-7 block for an
hv_sock ring: `dmesg | grep 'page allocation failure'` names the order and
`/proc/buddyinfo` shows the fragmentation. Relief without a restart:
`sudo sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches; echo 1 > /proc/sys/vm/compact_memory'`.
The flake sets `vm.compaction_proactiveness = 60`; on the Windows side,
`autoMemoryReclaim=gradual` with swap configured in `.wslconfig` kept the
failures at zero.

## `/mnt/c` returns `Input/output error`

When the drvfs mounts lose the Windows-side file server, `/mnt/c` and `/mnt/d`
answer `Input/output error`, and `powershell.exe` and `cmd.exe` fail the same
way because they live on `/mnt/c`. `flakelab doctor` does not see it: it checks
that the interop handler is registered, not the mounts. Never unmount the live
mount first, or a failed remount leaves the drive unmounted outright. Test on a
scratch mountpoint, `sudo mount -t drvfs 'C:\' /tmp/ctest -o metadata,uid=1000,gid=100`,
and swap only if that works. `UtilConnectVsock … port 50002 failed 110` means
the file server is gone: only a WSL restart from Windows recovers it, and that
ends every session, so it is the operator's call.

## The terminal loses focus every half minute

When a WSLg distro's compositor has crashed, Windows relaunches its `msrdc.exe`
client about every 30 seconds and each launch takes the keyboard focus from
the terminal. `tail /mnt/wslg/stderr.log` shows the relaunches. Only
`wsl --shutdown` from a Windows terminal clears it, which ends every session.

## A hard crash leaves broken git objects

After a crash of the VM or the host, checkouts can hold zero-length loose
objects and NUL-padded reflogs, and `gitchecker` stops at the first broken
repository. Find them with `git fsck --no-dangling` and
`find .git/objects -type f -empty ! -name '*.promisor'`; move the empty objects
aside, strip the NULs from `.git/logs/**`, point the branch back at its last
intact commit with `git update-ref`, then `git read-tree HEAD`. Compare with a
clone on another machine before recommitting. An empty stray `.git` directory
above the checkouts (`~/git/.git`, left by a tool that used `~/git` as its
session root) breaks `gitchecker` too; remove it once it is confirmed empty.

## A checkout inside a sync client's folder corrupts `.git`

A file-sync client (Synology Drive, OneDrive, Dropbox) that replicates a
checkout including `.git` leaves conflict copies of `config`, `index` or
`packed-refs` (`*_Conflict*` and similar), and git then fails in ways that look
like its own bugs. Run `find . -name '*_Conflict*'` and `git fsck` before
blaming git; keep checkouts outside synced folders or exclude `.git` from the
sync.

## `wsl.exe -d <distro> -- <command>` loses quoting

After `--`, `wsl.exe` hands the words, joined, to the login shell: quotes and
a `$?` inside them are lost, so a multi-word check runs only its first word.
Use `--exec`, which keeps argv but skips the login `PATH`, so name the shell by
its full path: `wsl.exe -d <distro> -u <user> --exec /run/current-system/sw/bin/zsh -c '…'`.
A `Failed to translate '\\wsl.localhost\…'` line on stderr is the working
directory not translating and is harmless.

## A localhost callback in WSL is refused: Windows excluded port ranges

A listener in WSL on 127.0.0.1, such as an OIDC login callback, is reachable
from the Windows browser only while no Windows excluded port range covers its
port. Hyper-V and WinNAT reserve those ranges at runtime, with no reboot or
config change, so a login that worked yesterday ends in "connection refused"
while every server-side step succeeds. Check with
`netsh.exe int ipv4 show excludedportrange protocol=tcp`. Reserved ranges in
the low thousands mean the TCP dynamic port range was moved there
(`MaxUserPort` under `HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters`):
remove it and restore the default with
`netsh int ipv4 set dynamic tcp start=49152 num=16384` (and `ipv6`), as
administrator. Never run `net stop winnat` from inside WSL: it hangs and cuts
WSL networking until Windows reboots.

## TCP connects, then stalls behind a host VPN tunnel

When Windows routes through a tunnel with a smaller MTU (WireGuard: 1420) and
no ICMP "fragmentation needed" reaches WSL, `eth0` keeps its larger MTU and
segments between the two sizes vanish. Connects succeed; the first large write
(a TLS ClientHello, a provider download, a git pack upload) stalls, mostly
against peers that advertise a large MSS. Compare `ping -M do -s 1392 <dst>`
(1420 bytes) with `-s 1393`: silent loss at 1421 is the black hole, while
"Message too long" means path MTU discovery works and the MTU is not the cause.
The fix is configuration (`net.ipv4.tcp_mtu_probing = 1`, an `eth0` MTU that
matches the tunnel, or an MSS clamp on the tunnel's far end), not a per-session
workaround.

## `cc1` segfaults in a Docker build

`gcc: internal compiler error: Segmentation fault … cc1`, even for an empty
`main`, came from a corrupted local image layer: `cc1` truncated to exactly
8 MiB. Compare the size and checksum of `$(gcc -print-prog-name=cc1)` with a
good image instead of chasing package versions or memory. `docker rmi` and a
re-pull reuse the cached layer: `docker builder prune -af`, then
`docker rmi <image>`, then pull.

## `ssh-keygen` without a terminal writes an unencrypted key

Without a TTY and with `DISPLAY` set (WSLg, an agent's shell), `ssh-keygen`
falls back to askpass; with no askpass program installed it prints
`ssh_askpass: exec(): No such file or directory`, takes an empty passphrase and
exits 0. Generate keys in a real terminal, then check with
`ssh-keygen -y -P "" -f <key> >/dev/null`: success means the key has no
passphrase. `nix/home/git-ssh.nix` sets `AddKeysToAgent yes` for every host,
so a key's first use loads it into the agent, which travels wherever
`ForwardAgent` is on; a key that must stay out needs an earlier `Host` block
with `AddKeysToAgent no`, or `-o AddKeysToAgent=no` per call.

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
