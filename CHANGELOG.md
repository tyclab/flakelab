# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog], and this project adheres to
[Semantic Versioning].

## [Unreleased]

### Added

- `flakelab.stateRoot` / `stateTranscripts` options for a shared state root synced across machines.
- A secret gate in front of the state root, reviewable with `flakelab backup --review-secrets`.
- The `flakelab` CLI, a single router binary for all subcommands, with deprecation shims for the old command names.
- `flakelab.claudeAgentDefaults` (default `false`): opt-in for the agent-box Claude Code settings — auto permission mode with its consent flag, Remote Control at startup, and removal of the four env vars that would defeat it.
- `flakelab.claudeMdExtra` (default `""`): personal workflow rules appended inside the managed block of `~/.claude/CLAUDE.md`, after the neutral text this repo ships.
- `flakelab.hostName` (default `flakelab`): sets `networking.hostName`, which nothing set before — every box came up as `nixos`. An existing box is renamed at its next update, effective at the next distro restart, and anything keyed on the hostname sees a new machine: the gate ledger does, so already-applied holds are offered once more after the rename. Set `hostName = "nixos"` in the overlay to keep the old name.
- `setup-wsl-nix.ps1 -RestoreInstance <name>`: names the backup instance the overlay-payload restore reads, for a distro whose payload was written under another distro name. A name the payload has no directory for is refused, listing the ones it has.
- `setup-wsl-nix.ps1 provision` on a fresh PC — no overlay, no `-Config`, an interactive console — asks for the four values a config cannot do without (Linux user, git name, git mail, profiles; an optional repo list last) and writes them as `<overlay>\files\config\user_data.yaml` before carrying on; that file is found on every later run, so `-Force` regenerates from it. The README bootstrap is one command. Non-interactive runs and `-DryRun` keep the refusal; the `.cmd` menu's config prompt now falls through to the questions on Enter.

### Changed

- `setup-wsl-nix.ps1 provision` with a config that carries no token (what the first-run wizard writes) skips the credential-copy prompt and the per-name "not in user_data.yaml" lines; the missing SSH key / secrets.env note reads as optional, with `flakelab update` as the way to enable the deferred steps later.
- `flakelab backup --restore` is now additive: it no longer deletes local files the backup does not have.
- `flakelab.bitwardenServer` defaults to `null`, which skips the `bw config server` activation entirely; set it to name a region.
- `files/config/claude/CLAUDE.md`, shipped verbatim into every `~/.claude/CLAUDE.md`, is reduced to facts about the distro; the workflow rules moved to `claudeMdExtra`.
- `flakelab doctor` skips its GitLab checks (token, `glab auth`, the SSH probe) when the overlay configures no `gitlabGroups`, `repos` or `kiroPluginRepo`.
- `setup-wsl-nix.ps1 provision` / `bootstrap` / `generate` now refuse when there is no overlay and no `-Config`, instead of provisioning this repo's placeholder identity. `status` still reports the fallback, and the `setup-wsl-nix.cmd` menu asks for a config path.
- A config that names only `repos:` — no `profiles:`, no `gitlab_groups:` — is accepted by both overlay generators, for adopters with no GitLab.
- The managed `permissions.deny` floor denies every force push and remote-branch deletion, not only those naming `main`; `worktree.baseRef` is no longer asserted.
- The agent instructions file is `AGENTS.md`, and it is the only one: the repo ships no root `CLAUDE.md`. `ARCHITECTURE.md`'s "Known gaps" moved into `known-issues.md` as "Known limitations".

### Removed

- `HANDOVER.md` and every pointer to it; open work is tracked in the issue tracker, not in the tree.

### Fixed

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

[Keep a Changelog]: https://keepachangelog.com/en/1.1.0/
[Semantic Versioning]: https://semver.org/spec/v2.0.0.html
