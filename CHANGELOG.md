# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog], and this project adheres to
[Semantic Versioning].

## [Unreleased]

### Added

- `bwu` / `bwl` shell functions: `bwu` unlocks the Bitwarden vault on the TTY and parks the session token in mode-600 `~/.config/tyc/bw-session`; every shell exports it as `BW_SESSION` from there, so agents inherit an unlocked `bw` without the token crossing a command line or a transcript. `bwl` locks and removes the file. The token is per-unlock, so it lives outside `secrets.env` and outside `flakelab backup`.
- `flakelab.target` (default `wsl`): the platform a system is built for, and the module set in `nix/targets/` that goes with it — `wsl` is the NixOS-WSL distro, `proxmox-vm` a Proxmox guest. It rides outside `userData` (`mkSystem { target = "proxmox-vm"; userData = { … }; }`, or as a top-level key of the legacy attrset) because `imports` cannot be conditional: the choice is made before the module system runs, which is also why the option is read-only afterwards.
- `nixosConfigurations.proxmox-vm`: the tracked placeholders on the new target — cloud-init for the hostname, network and keys PVE hands the guest, a qemu-guest-agent that refuses fs-freeze so `vzdump` does not wait for a thaw that never comes, keys-only sshd, and a root filesystem that grows into whatever disk it is given.
- `flakelab.flakeAttr` (default `"default"`): the `nixosConfigurations` attribute `flakelab update` switches into, for an overlay flake that declares more than one box.
- `checks.targets`: `nix flake check` instantiates both systems and builds neither, asserting that each one carries its own platform and none of the other's.
- `flakelab.backupRoot` (default `null`, resolving to `${repoPath}/files/config` as before): the `flakelab backup` payload root, for a target with no Windows mount to point it at instead.
- `test-flakelab-cli`: the sixth offline suite, covering the router's target gate.

### Changed

- `flakelab.windowsUsername` is optional and defaults to `null`. It feeds the zsh jump out of the Windows profile directory, which only the `wsl` target has, so an overlay for any other target leaves it out.
- `nix/configuration.nix` is the system layer every target shares; the NixOS-WSL settings, the interop hazard note and `system.stateVersion` live in `nix/targets/wsl.nix`.
- `flakelab <command>` refuses the four WSL-only verbs (`provision`, `build-distro`, `test-provision`, `distro-name`) with exit 2 on any target other than `wsl`, and drops them from `--help` and its did-you-mean suggestions.
- `flakelab doctor`'s WSL interop check runs only when the target is `wsl`; every other target gets a single `ok` line instead of a spurious failure.
- `flakelab backup`'s per-instance path resolves `WSL_DISTRO_NAME`, then `FLAKELAB_INSTANCE` (exported by the nix wrapper from `hostName` on any non-`wsl` target), before falling back to the `wsl.exe` probe.
- `BROWSER` is set only on the `wsl` target (`wsl-open` needs a Windows default browser to hand a URL to); other targets' CLIs print the URL themselves.
- `flakelab.mcpPlaywright`'s server registration, and Claude's Playwright MCP bridge env, are gated on the `wsl` target too — extension mode's Windows Chrome path is meaningless elsewhere; a trace warns when `mcpPlaywright` is set on another target.
- `~/.claude/CLAUDE.md`'s managed block is now a target-neutral core plus a per-target file (`target-wsl.md` or `target-proxmox-vm.md`), so a Proxmox guest gets its own facts instead of a WSL box's `/mnt/c` and WSL-verb notes.

## [0.1.0] - 2026-08-27

First tagged release. The project has been in daily use on two machines since
before the public flip; this marks the point where adopters get a version to
pin to instead of a moving `main`.

### Added

- `flakelab.stateRoot` / `stateTranscripts` options for a shared state root synced across machines.
- A secret gate in front of the state root, reviewable with `flakelab backup --review-secrets`.
- The `flakelab` CLI, a single router binary for all subcommands, with deprecation shims for the old command names.
- `flakelab.claudeAgentDefaults` (default `false`): opt-in for the agent-box Claude Code settings — auto permission mode with its consent flag, Remote Control at startup, and removal of the four env vars that would defeat it.
- `flakelab.claudeOutputStyle` (default `null`): the Claude Code output style asserted into `settings.outputStyle` on every activation, so a style survives a fresh box instead of living in a git-ignored `settings.local.json`. Null leaves the key alone.
- `flakelab.claudeMdExtra` (default `""`): personal workflow rules appended inside the managed block of `~/.claude/CLAUDE.md`, after the neutral text this repo ships.
- `flakelab.hostName` (default `flakelab`): sets `networking.hostName`, which nothing set before — every box came up as `nixos`. An existing box is renamed at its next update, effective at the next distro restart, and anything keyed on the hostname sees a new machine: the gate ledger does, so already-applied holds are offered once more after the rename. Set `hostName = "nixos"` in the overlay to keep the old name.
- `setup-wsl-nix.ps1 -RestoreInstance <name>`: names the backup instance the overlay-payload restore reads, for a distro whose payload was written under another distro name. A name the payload has no directory for is refused, listing the ones it has.
- `setup-wsl-nix.ps1 provision` on a fresh PC — no overlay, no `-Config`, an interactive console — asks for the four values a config cannot do without (Linux user, git name, git mail, profiles; an optional repo list last) and writes them as `<overlay>\files\config\user_data.yaml` before carrying on; that file is found on every later run, so `-Force` regenerates from it. The README bootstrap is one command. Non-interactive runs and `-DryRun` keep the refusal; the `.cmd` menu's config prompt now falls through to the questions on Enter.
- `BACKLOG.md`: planned work, tracked in the repository alongside the code it describes rather than in the GitHub issue tracker.
- `flakelab.kiroTrustAll`, `flakelab.claudeTrustAll` and `flakelab.mcpPlaywright` (all default `false`): the operator's full-trust agent surface is now opt-in. Adopters no longer inherit `kk` (`kiro-cli chat --trust-all-tools`), `cc` (`claude --dangerously-skip-permissions`), `cli.json`'s `chat.disableTrustAllConfirmation`, or a browser-driving MCP server. Trust-all outranks the Kiro agent's `deniedCommands`, so the destructive floor does not apply under it — which is why it is a decision and not a default.

### Changed

- `flakelab update` bumps the flakelab input whatever its shape — a remote pin moves to its latest commit instead of needing `nix flake update flakelab` by hand. A local flakelab input is named rather than silently re-locked: `flakelab update` says which checkout it built from, and `flakelab doctor` warns on `path:`/`git+file:` inputs.
- `setup-wsl-nix.ps1 provision` with a config that carries no token (what the first-run wizard writes) skips the credential-copy prompt and the per-name "not in user_data.yaml" lines; the missing SSH key / secrets.env note reads as optional, with `flakelab update` as the way to enable the deferred steps later.
- `flakelab backup --restore` is now additive: it no longer deletes local files the backup does not have.
- `flakelab.bitwardenServer` defaults to `null`, which skips the `bw config server` activation entirely; set it to name a region.
- `files/config/claude/CLAUDE.md`, shipped verbatim into every `~/.claude/CLAUDE.md`, is reduced to facts about the distro; the workflow rules moved to `claudeMdExtra`.
- `flakelab doctor` skips its GitLab checks (token, `glab auth`, the SSH probe) when the overlay configures no `gitlabGroups`, `repos` or `kiroPluginRepo`.
- `setup-wsl-nix.ps1 provision` / `bootstrap` / `generate` now refuse when there is no overlay and no `-Config`, instead of provisioning this repo's placeholder identity. `status` still reports the fallback, and the `setup-wsl-nix.cmd` menu asks for a config path.
- A config that names only `repos:` — no `profiles:`, no `gitlab_groups:` — is accepted by both overlay generators, for adopters with no GitLab.
- The managed `permissions.deny` floor denies every force push and remote-branch deletion, not only those naming `main`; `worktree.baseRef` is no longer asserted.
- The agent instructions file is `AGENTS.md`, and it is the only one: the repo ships no root `CLAUDE.md`. `ARCHITECTURE.md`'s "Known gaps" moved into `known-issues.md` as "Known limitations".
- Every third-party `pre-commit` hook is pinned to an immutable commit SHA (`rev: <sha>  # frozen: <tag>`) rather than a mutable tag, which a compromised maintainer can repoint without changing the version string.
- `@jarahkon/hass-mcp-server` is version-pinned like the other MCP servers; it was resolved fresh by `npx --yes` on every start while holding a live `HASS_TOKEN`.
- Renovate waives `minimumReleaseAge` and automerges `@playwright/mcp` alone: the Playwright MCP Bridge Chrome extension auto-updates and cannot be pinned, so a lagging server is rejected with "unsupported protocol version" and a release-age hold is a guaranteed outage window. Every other package keeps the repo-wide hold.

### Removed

- `HANDOVER.md` and every pointer to it; open work is tracked in `BACKLOG.md`.

### Fixed

- A plugin named in `flakelab.claudePlugins` is now enabled as well as installed (`plugin enable` exits 1 once a plugin is enabled, so that case is not reported as a failure). Claude Code loads a plugin only when `settings.enabledPlugins` names it, and `plugin install` leaves that key alone, so a plugin disabled once stayed inert on every later rebuild — its MCP servers and agents missing from sessions while activation reported success. Opting out is still dropping it from `claudePlugins`, which uninstalls it.
- `setup-wsl-nix.ps1` no longer dies on a native command's stderr: under `ErrorActionPreference = 'Stop'` Windows PowerShell 5.1 turns a redirected stderr line into a terminating error, and wsl.exe's transient "Failed to start the systemd user session" right after the first switch killed the provision at the interop probe. Probe-style native calls now run through `Invoke-NativeQuiet` — including the `git ls-files flake.lock` check before switch 1, which aborted a migration whose overlay does not track its lock.
- An unattended `migrate` now writes its completion marker.
- `gitpublisher`'s secret gate survives a large hook report: it read the report through a pipe, where `grep -q` closed it at the first match and `pipefail` turned the resulting SIGPIPE into "no secret found", reporting a real leak as a lint stop. The same report also broke the JSON verdict, since one argv element caps at ~128 KB and it was passed to `jq --arg`.
- `setup-wsl-nix.ps1` refuses a `#` in the checkout or overlay path (the flake-ref fragment delimiter, so `--flake <path>#default` was cut at it) and skips a key filename containing a single quote instead of copying the wrong file.
- The four Claude activations that write `~/.claude/settings.json` (settings policy, statusline, Playwright env, WhatsApp env) are gated on `installClaude`, so a box without Claude Code no longer gets a settings.json.
- `cloneExclude` entries are ERE-escaped and shell-quoted before reaching `grep`, and a grep failure aborts instead of yielding an empty clone list.
- `flakelab backup --restore` recreates `~/.kube` 0700 with 0600 files, and no longer creates it at all under `--dry-run`.
- `path:` flake URLs are percent-encoded, so a checkout or overlay under a path containing a space (`C:\Users\First Last\git\`) builds instead of failing every rebuild.
- `flakelab update` re-locks a `path:` flakelab input before the switch, so a rebuild after a `git pull` no longer evaluates the previously locked snapshot of the flake.
- Flow-style YAML lists (`profiles: [a, b]`) are parsed as lists by both overlay generators, instead of reaching the overlay as a literal string.
- `gitpublisher` no longer reads pre-commit's cold-cache "Installing environment for .../gitleaks" line as a secret finding.

[0.1.0]: https://github.com/tyclab/flakelab/releases/tag/v0.1.0
[Keep a Changelog]: https://keepachangelog.com/en/1.1.0/
[Semantic Versioning]: https://semver.org/spec/v2.0.0.html
