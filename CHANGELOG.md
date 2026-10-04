# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog], and this project adheres to
[Semantic Versioning].

## [Unreleased]

### Added

- `flakelab doctor` has a "Dashboard" section: it warns when `flakelab-web.service` still runs a previous generation's code after `flakelab update` (activation never restarts it) and names the restart, and when the unit is loaded but down.
- `flakelab.boxName`: a second box built from the same overlay that keeps the shared hostname names itself here, and that name — not the hostname or the distro name — becomes its backup payload instance (`instances/<name>`), its slug manifest in the state root and the gate ledger's `host`. Before, two such boxes wrote one instance and one manifest through the sync, and a ruling taken on one counted as the other's. Null keeps everything on the distro name and the hostname, as before.
- Opt-in GitHub discovery for `flakelab clone`: `cloneGithub` defaults off, and `githubOwners` selects users or organizations (empty means the authenticated account and its organizations). Paginated discovery skips archived, disabled and empty repositories, honors `cloneExclude`, and uses the existing `gh` credentials.
- `flakelab web`: a browser dashboard for the tycswap logins and the sessions on 127.0.0.1:8321 behind a token; `flakelab.web.enable`, `flakelab.web.terminal` (ttyd), `flakelab.web.logo`.
- `flakelab.stateSyncthing`: the state root replicated by Syncthing through an untrusted hub; needs a Linux `stateRoot` and `sopsSecretsFile`.
- A bare `flakelab` opens a menu, and a command missing an argument asks for it at a terminal; `FLAKELAB_NO_PROMPT=1` turns every prompt off.
- `flakelab.mcpBrowsers.headless`: a `playwright-headless` MCP server in Claude and Codex on any target.
- `flakelab.mcpShared` and `flakelab mcp` (`connect`, `login`, `status`, `import-codex`): OAuth MCP accounts shared by Claude and Codex, one credential host; a refusal (unknown or `login-required` account, wrong host, an overwriting `import-codex`) exits 2.
- `flakelab notify`: an ntfy push when an agent session waits (`NTFY_URL`, `NTFY_TOKEN`); `flakelab.notify.enable` and `flakelab.notify.events` write the hook; a bare run at a terminal prints its usage.
- `flakelab.mosh.enable` (default `false`, proxmox-vm only) and `files/config/windows/enable-openssh-host.ps1` for OpenSSH Server on a WSL host.
- `flakelab sessions --start <tool> [dir]` and `--attach [id|window]`: sessions hosted in the `agents` tmux session; `tmux` joins the package set.
- `flakelab sessions` lists Codex sessions and sessions started by `tycswap run`; saved lines carry a tool column.
- `flakelab sessions --recent [hours]` (default 24) lists recently changed sessions that are not running, including ones synced from another box.
- `flakelab sessions --autosave` on the `flakelab-sessions-autosave` timer (`flakelab.sessionsAutosaveInterval`, default `5min`); `--resume`/`--open` read the previous boot's file.
- `flakelab.claudeRemoteControl` (default `false`): Claude Code's `remoteControlAtStartup` without the `claudeAgentDefaults` bundle.
- `remote-sessions.md`: the design for remotely reachable sessions.
- Codex permission profiles under `codexAutoReview`, enforced through managed requirements with `codexEnforcePermissions`; see `CODEX-PERMISSIONS.md`.
- `flakelab backup` carries Codex config, rules, hooks, skills and token files as `codex/`; `~/.codex/memories/` and, under `stateTranscripts`, `~/.codex/sessions/` sync.
- The Codex CLI via its official installer into `~/.local/bin` (`flakelab.installCodex`, default `true`), with `bubblewrap`.
- `flakelab-switch-result`: one verdict and exit code for a switch (`applied` 0, `degraded` 4, `activation-failed` 2, `unverified` 3, `reboot-required` 100).
- A `soft_deny` entry in the `claudeAutoMode` default for tool calls that print the rendered secret files to the transcript.
- A `SessionEnd` hook in `~/.claude/settings.json` that starts `flakelab-state-sync.service`, written only while the state sync is scheduled.
- Session side files (`tool-results/`, a subagent's `.meta.json`) sync with the transcripts under `stateTranscripts`, through the secret gate.
- `provision`, `generate`, `init` and `flakelab overlay-gen` leave the overlay as a git repository with one commit and no remote.
- `overlay_url` in `user_data.yaml` (`--overlay-url`, `flakelab.overlayUrl`): the overlay's remote, added as `origin` and excluded from `flakelab clone`.
- `test-nix-update`, `test-nix-doctor`, `test-clone-repos`, `test-activate-hooks`, `test-report-stale-repos` and `test-nix-provision`: offline suites in `make test` and `nix flake check`; `checks.state-syncthing` runs the password reader against a fixture.
- `GLAB_NO_PROMPT=1` in every login session.
- The Claude permissions merge installs the marketplace's `recommended-ask.json` as `permissions.ask`, asserted whole.
- `installTycswap` (default `true`): tycswap, the Claude Code and Codex account switcher, pinned in `flake.nix` and built as a flake check; `flakelab.tycswapAutoSwitchInterval` schedules `tycswap auto --once` on the `flakelab-tycswap-autoswitch` user timer (the quota hook ticks it too), `flakelab backup` carries its store as `tycswap/`, `flakelab doctor` has a `Switcher` section, `flakelab web` reads `tycswap list --json`, `flakelab sessions` finds its profile sessions.

### Changed

- Tycswap is pinned to v0.7.2: `tycswap web` and `tycswap app` end with 0 on Ctrl-C as on SIGTERM, with their cleanup run (the app removes its remote token file; v0.7.1 had fixed SIGTERM alone). v0.7.1 made a Codex remove or disable hold the Codex store lock (a remove during a usage refresh of the same account could leave a live credential file behind) and a busy Codex store a lock error (409 on the dashboard) for every Codex verb. v0.7.0 brought `tycswap app`, the dashboard as a menu-bar or notification-area application, `tycswap upgrade` replacing a release binary in place, `tycswap app --remote` as a Windows tray for the app in a WSL distro, Codex accounts in the dashboard and the tray, and API-key accounts with a base URL.
- `flakelab.claudeAgentDefaults` no longer implies Remote Control: `remoteControlAtStartup` and the removal of the four env vars its feature flags need follow `flakelab.claudeRemoteControl` alone, so an agent box can keep its sessions off the app. A box that had Remote Control through the bundle sets `claudeRemoteControl = true;` to keep it.
- The dashboard reloads every 15 seconds instead of 30, and not while its tab is hidden.
- The prompt's git segment is coloured; the oh-my-zsh theme defaults to `robbyrussell` (`lib.mkDefault`).
- The system-wide `compinit` in `/etc/zshrc` is off (`programs.zsh.enableGlobalCompInit = false`).
- tmux and the dashboard's terminal use the dashboard's accent colours.
- `flakelab update` reports whether the flakelab input moved, with old and new rev and, from a local clone, the commit count.
- `flakelab update` / `update-all` turn a plain-directory overlay into a git repository with one commit; `FLAKELAB_STALE_OK=1` leaves it plain.
- `flakelab.stateSyncInterval` no longer needs `backupAutostart`, which now only schedules the daily full pass.
- `flakelab sessions --resume` / `--open` resume by id when the saved directory does not exist on this box.
- The `claudeAutoMode` default states the allowed force-push form in `soft_deny` prose instead of two `Bash()` patterns.
- The `permissions.deny` floor shrinks to the two `--mirror` rules; retired rules are listed in `claudeDenyStale` and removed from existing settings.
- `flakelab update` / `update-all` pull a clean overlay checkout that is behind (`git pull --rebase`); a dirty tree refuses unless `FLAKELAB_STALE_OK=1`.
- A usage error (an unknown flag or argument) exits 2 on every `flakelab` command; failed work exits 1, and the doctor's 1 is a failed check.
- `flakelab doctor` warns on a `skip-healthcheck` marker, lists every section in `--help`, and its summary line says `flakelab doctor`.
- `teams` / `teamCliTools` in `userData` are deprecated spellings of `profiles` / `profileCliTools`: still read, to go in a later release.
- `flakelab build-distro` and `flakelab test-provision` share their checks (`files/scripts/lib/distro-check.zsh`) and both accept the `WSLInterop-late` handler.

### Removed

- `flakelab accounts`, the zsh account switcher (never in a release): tycswap does the job. `flakelab.accounts.*` is gone; a box that stored logins in `~/.local/state/flakelab/accounts` moves them with the loop in README, "Migrating from flakelab accounts", and `flakelab doctor` warns until the old store is removed.
- `wsl-open` from the `wsl` target's packages: the flake's `xdg-open` is the opener, and `BROWSER` names it.
- The `cwsl` alias.
- The deprecation shims for the old command names (`nix-update`, `nix-doctor`, `nix-backup`, `nix-provision`, `nix-clone-repos`, `build-dev-wsl-nix`, `test-provision-nix`); `flakelab <verb>` is the only form.
- Kiro CLI support, whole: the installer, plugin checkout, `k`/`kk`/`kwsl` aliases, the MCP merge, its `sessions` and `accounts` adapters, doctor and health sections, and the `kiro-cli-json`/`kiro-mcp-merge` checks. An overlay still setting `installKiro`, `kiroPluginRepo`, `kiroTrustAll` or `mcpPlaywright` fails to evaluate until the line goes; `~/.kiro` is not touched.
- Its leftovers: the `renovate-digest` manager and `git-refs` rule, `nix/home/mcp.nix` (folded into `claude.nix`), the `FLAKELAB_ACCOUNTS_COOLDOWN` read, and the tracked `files/config/shared/ssh/keys/.gitkeep`.

### Fixed

- `flakelab sessions` names its saves and autosaves `<hostname>-<machine>-…`, the first twelve hex digits of `/etc/machine-id` behind the hostname, and the default `--resume`/`--open` read only this box's files. Two WSL distros built from one overlay share the hostname and, through the sync, the save directory; named after the host alone, the other box's newer autosave was what a reboot here reopened. A file named explicitly is still resumed whichever box wrote it; files from before the rename are left alone and are not read by default.
- `flakelab backup --review-secrets` scrubs a transcript secret where it sits: every line that holds it literally (the scanner reports a match ending at a line break one line early, and one finding where a line holds the token twice), and for a secret the scanner decoded out of a base64, percent-encoded or hex run, that run. Before, both re-scanned dirty and the file stayed held with the delete pending forever.
- A `delete` settles each record it carried out; a record whose scrub failed stays held and is retried on its own. Before, one stuck file kept every record of that secret held.
- `flakelab doctor` finds a held transcript's synced copy at any depth under the state root; subagent transcripts and workflow journals were called "held back whole, never synced" while synced.
- `test-nix-doctor` keeps the host's `tycswap` out of its tool shadow, so its stub runs on a box with the switcher installed.
- `checks.mcp` runs its headless browser test with ASLR on: in the Nix build sandbox, which turns ASLR off, a host uprobe on libc `setenv` left the browser's zygote spinning until the 180 s launch timeout.
- `flakelab backup` and `--restore` skipped tycswap's Claude credential and config snapshots: the store names them with a leading dot and the glob did not match dotfiles (#179). The Codex snapshots, named without one, were carried; the fixture now uses the real names.
- Activation removes `env` keys in `~/.claude/settings.json` and `mcpServers` in `~/.claude.json` it no longer renders, recorded in `~/.local/state/flakelab/activation-rendered/`.
- `flakelab update` fetches the overlay's inputs as the caller before the switch, so a collected private `git+ssh` input no longer fails the rebuild.
- The overlay generators name every key, field or line they drop (never an empty top-level key) instead of misreading or ignoring it; `setup-wsl-nix.ps1` refuses a `target:` other than `wsl`.
- `NTFY_URL` and `NTFY_TOKEN` under `custom_env_vars` are withheld from the generated overlay by both generators, like every other secret.
- `flakelab test-provision` derives the expected subcommand list from the router's own table instead of a count that had rotted.
- `flakelab clone` uses the first `sshKeys` entry that exists on disk, as the activation steps do; `clone-repos` names a missing key file as such.
- Every `--help` names the `flakelab <verb>` form; no usage text names a retired script name.
- `HA_URL`/`HA_TOKEN` are derived in `.zshenv`, so a non-interactive shell gets them too.
- The `sessionVariables` comments in the generators, the template and the option say which names gate a Claude MCP server (`GRAFANA_URL`, `WHATSAPP_BRIDGE_HOST`).
- `flakelab backup --restore --from` restores the source's Claude and Codex memory, with or without the state root available.
- `flakelab sessions`: a row without a session id is described as listed but not saveable; `--recent` sorts across all tools by time.
- `gitchecker --help` no longer calls itself read-only.
- `flakelab update` warns when `inputs.flakelab.url` names a rev, which `nix flake update` cannot move.
- tmux `set-clipboard on`, so an OSC 52 copy reaches the outer terminal; `checks.tmux-clipboard` covers it.
- `gitchecker` asks, in the foreground, whether to fast-forward a behind branch with a dirty tree.
- No check depends on a pipe ending in `grep -q` or `head -1` under `pipefail`; `test-flakelab-cli` fails on that pattern.
- `--help` prints help and runs nothing on every command; `flakelab clone` and `distro-name` refuse any argument with exit 2.
- `setup-wsl-nix.ps1` lists a source checkout's `files/config/custom/` only for a config read from that checkout.
- The `wsl` target moves its processes into `/flakelab-<id>/init.scope` when PID 1's cgroup denies users; `flakelab doctor` gains a "systemd cgroup" section.
- `known-issues.md` says the `wsl --shutdown` interop heal holds only until the next stop of a systemd distro.
- `checks.cli-installers` passes on a builder without the sandbox.
- Codex fleet settings are in `/etc/codex/config.toml`; the user config stays writable.
- An offline switch defers the Claude Code and Codex install instead of failing the health check.
- `flakelab doctor` checks only the AI CLIs the overlay installs (`FLAKELAB_AI_CLIS`).
- `flakelab update` and `flakelab doctor` recognise a `git+file:` flakelab input as local again.
- A transcript line whose secret crosses a JSON string boundary is redacted per string instead of the file being held back.
- The `flakelab-state-sync` timer finishes within `TimeoutStartSec` again; line counts are cached in `~/.local/state/flakelab/state-sync/transcript-lines`.
- Keys, `secrets.env`, `user_data.yaml` and the backup payload moved out of the overlay: `flakelab.backupRoot` defaults to `${repoPath}-payload`. No migration: move them by hand.
- `setup-wsl-nix.ps1` switches from `path:<overlay>#default`, as `flakelab update` does.
- The overlay's first commit refuses paths the template `.gitignore` ignores (`files/scripts/lib/overlay-git.zsh`, `Get-OverlayGitLeaks`).
- The rendered git config declares the `gh`/`glab` credential helper for `https://github.com`, `https://gist.github.com` and `https://gitlab.com`.
- The `wsl` target installs an `xdg-open` (`files/scripts/xdg-open`) for CLIs that ignore `BROWSER`; `flakelab doctor` fails without one.
- `setup-wsl-nix.ps1`, `build-distro`, `flakelab update` and `flakelab-bootstrap` act on `flakelab-switch-result`'s verdict, not the switch's exit status.
- `setup-wsl-nix.cmd <args>` passes the script's exit code on.
- A failed `setup-wsl-nix.ps1` switch no longer leaves a root-owned `flake.lock` in the overlay.
- `flakelab update` takes back a root-owned overlay `flake.lock` before the re-lock and after the switch.
- Script output no longer rewrites `%` or backslashes in the data it prints.
- `flakelab sessions --save`, `--autosave`, `--resume` and `--open` write one line per session id instead of per process.
- The transcript sync parks the other branch of a forked session under `diverged/` instead of dropping it.
- Syncthing temps and folder metadata count as sync artifacts.
- `flakelab update`'s fetch warning names the checkout it could not fetch.
- `autoUpdates` is asserted `true` in `~/.claude.json`, and `autoUpdate` is set for every configured marketplace.
- `setup-wsl-nix.ps1` and `files/config/secrets.env.example` name `SYNOLOGY_URL` and `SYNOLOGY_VERIFY_SSL` as the non-secret keys.
- The provisioner's ssh-agent load fails on an empty agent.
- The proxmox-vm target links `/bin/bash`.
- The flakelab user lingers (`users.users.<name>.linger = true`), so `user@<uid>` and the ssh-agent survive the end of a session.
- `clone-repos` runs ssh in `BatchMode` and refuses up front when the key is encrypted and the agent is empty.
- `flakelab update` / `update-all` switch an overlay that is not a git checkout or has no remote after one info line.
- `setup-wsl-nix.ps1` treats a sops-enrolled overlay as configured.
- The Claude marketplace fetch uses the first `sshKeys` entry that exists on disk.
- `flakelab update` updates an installed Claude plugin whose marketplace version changed.
- The state sync's memory index keeps one line per memory file, and the memory mirror is newest-wins.
- The state sync propagates memory deletions through tombstones (`<slug>/memory-tombstones/<file>`).
- The clone sweep fast-forwards a behind default branch even when the checkout cannot move.
- A switch that builds the same generation re-runs a pending activation; `flakelab doctor` reads `activation-deferred`.
- The GitLab group discovery skips a project with no commits.
- `flakelab backup` recopies a file written during the run before calling it a mismatch.
- A restore no longer writes `~/.claude/plugins/known_marketplaces.json`.
- `flakelab doctor`'s git-config check reads `user.email` with `--global`.
- `flakelab update` no longer exits 4 where WSL's `wsl-mnt-guard.service` has `ExecStart=/bin/true`: the WSL target's drop-in points it at the Nix-store `true` (known-issues.md).

## [0.3.0] - 2026-09-02

### Added

- `flakelab sessions` with `--save`, `--resume` and `--open`: the running Claude Code sessions, saved and resumed across a restart.
- `flakelab.sopsSecretsFile` (default `null`) and `flakelab.sopsAgeKeyFile` (default `/var/lib/sops-nix/key.txt`): opt-in sops-nix secrets rendered to `/run/secrets/tyc-env`.
- Slug manifests and `flakelab backup --state-gc` (`--force` to remove); a manifest older than 7 days (`FLAKELAB_STATE_GC_MAX_AGE_DAYS`) aborts.
- `flakelab backup --revisit-keeps`: re-holds `keep` findings for the next `--review-secrets`.
- `flakelab backup --state-only`: push and pull of the state root only.
- `flakelab.stateSyncInterval` (default `null`): `--state-only` on the `flakelab-state-sync` timer; needs `stateRoot` and `backupAutostart`.
- `flakelab doctor` reports secret-gate findings held back from the state root.

### Fixed

- The Proxmox seed's `flakelab-bootstrap` adds `OVERLAY_KNOWN_HOSTS` to the user's `~/.ssh/known_hosts`.
- History conflict copies in the `_<host>_<date>_Conflict.zsh_history_merged` shape are folded and removed.
- `flakelab sessions --open` no longer reports `wt.exe failed` for the first session.
- `flakelab update` waits for the boot activation (`FLAKELAB_BOOT_WAIT`, default 180s; `FLAKELAB_BOOT_OK=1` skips).
- `vm.compaction_proactiveness` is 60 on every target, so new WSL sessions do not stall.
- `gitchecker` skips a repo with no origin or an unsupported forge instead of aborting (#40).
- `flakelab update` refreshes every Claude plugin marketplace and replays the permissions merge after each switch.
- The transcript redactor handles overlapping and duplicate findings (#36).
- `ssh-agent.service` carries `X-RestartIfChanged=false`, so activation no longer empties the agent.
- Both backup oneshots carry `TimeoutStartSec` (2h full, 30min state-only).
- ARCHITECTURE.md no longer says the daily timer converges both sides.
- Activation no longer stops or restarts the backup oneshots (`X-RestartIfChanged=false`).
- Transcript staging is incremental.
- A `d` answer in `--review-secrets` records the delete ruling immediately.
- `flakelab doctor` no longer warns about "0 secret findings held back".
- Transcript sync includes subagent transcripts (`<slug>/<session>/subagents/*.jsonl`).
- Conflict-copy pairing understands a marker before the extension (`MEMORY_<host>_<date>_Conflict.md`).
- Transcript conflict copies are folded grow-only and then removed.

## [0.2.0] - 2026-08-28

### Added

- `bwu` / `bwl`: unlock and lock the Bitwarden vault, with the token in `~/.config/tyc/bw-session` exported as `BW_SESSION`.
- `flakelab.target` (default `wsl`, or `proxmox-vm`), set in `mkSystem { target = ...; }` and read-only afterwards.
- `nixosConfigurations.proxmox-vm`.
- `flakelab.flakeAttr` (default `"default"`): the `nixosConfigurations` attribute `flakelab update` switches into.
- `checks.targets`: instantiates both systems.
- `flakelab.backupRoot` (default `null`, resolving to `${repoPath}/files/config`).
- `test-flakelab-cli`.
- `.#proxmoxImage`: the Proxmox seed image as a qcow2.
- `flakelab-bootstrap`: the proxmox-vm one-shot unit reading `/etc/flakelab/bootstrap.env` (`OVERLAY_URL` required).
- `.github/workflows/release.yml`: a `v*` tag uploads `flakelab-proxmox-vm-<tag>.qcow2` and its `.sha256`.
- `nix-overlay-generate --target <wsl|proxmox-vm>` (default `wsl`) and the `target:` key in `user_data.yaml`.

### Changed

- `flakelab.windowsUsername` is optional and defaults to `null`.
- `nix/configuration.nix` is the shared system layer; WSL settings live in `nix/targets/wsl.nix`.
- `flakelab` refuses `provision`, `build-distro`, `test-provision` and `distro-name` with exit 2 on targets other than `wsl`.
- `flakelab doctor`'s WSL interop check runs only on the `wsl` target.
- `flakelab backup`'s instance path resolves `WSL_DISTRO_NAME`, then `FLAKELAB_INSTANCE`, then `wsl.exe`.
- `BROWSER` is set only on the `wsl` target.
- `flakelab.mcpPlaywright` and Claude's Playwright MCP bridge env are gated on the `wsl` target.
- `~/.claude/CLAUDE.md`'s managed block is a shared core plus `target-wsl.md` or `target-proxmox-vm.md`.

## [0.1.0] - 2026-08-27

First tagged release.

### Added

- `flakelab.stateRoot` / `stateTranscripts` options for a shared state root synced across machines.
- A secret gate in front of the state root, reviewable with `flakelab backup --review-secrets`.
- The `flakelab` CLI, a single router for all subcommands, with shims for the old command names.
- `flakelab.claudeAgentDefaults` (default `false`): auto permission mode, Remote Control at startup.
- `flakelab.claudeOutputStyle` (default `null`): asserted into `settings.outputStyle`.
- `flakelab.claudeMdExtra` (default `""`): rules appended inside the managed block of `~/.claude/CLAUDE.md`.
- `flakelab.hostName` (default `flakelab`): sets `networking.hostName`; set `hostName = "nixos"` to keep the old name.
- `setup-wsl-nix.ps1 -RestoreInstance <name>`: the backup instance the restore reads.
- `setup-wsl-nix.ps1 provision` on a fresh PC asks for the required values and writes `user_data.yaml`.
- `BACKLOG.md`: planned work.
- `flakelab.claudeTrustAll` and `flakelab.mcpPlaywright` (default `false`): the `cc` alias and a browser-driving MCP server are opt-in.

### Changed

- `flakelab update` bumps the flakelab input whatever its shape; `flakelab doctor` warns on `path:`/`git+file:` inputs.
- `setup-wsl-nix.ps1 provision` with a token-less config skips the credential-copy prompt.
- `flakelab backup --restore` is additive: it no longer deletes local files the backup does not have.
- `flakelab.bitwardenServer` defaults to `null`, which skips `bw config server`.
- `files/config/claude/CLAUDE.md` holds distro facts only; workflow rules moved to `claudeMdExtra`.
- `flakelab doctor` skips its GitLab checks when the overlay configures no `gitlabGroups` or `repos`.
- `setup-wsl-nix.ps1 provision` / `bootstrap` / `generate` refuse without an overlay or `-Config`.
- A config with only `repos:` is accepted by both overlay generators.
- The `permissions.deny` floor denies every force push and remote-branch deletion; `worktree.baseRef` is no longer asserted.
- `AGENTS.md` is the only agent instructions file; "Known gaps" moved to `known-issues.md` as "Known limitations".
- Every third-party `pre-commit` hook is pinned to a commit SHA.
- `@jarahkon/hass-mcp-server` is version-pinned.
- Renovate waives `minimumReleaseAge` and automerges `@playwright/mcp` alone.

### Removed

- `HANDOVER.md` and every pointer to it; open work is tracked in `BACKLOG.md`.

### Fixed

- A plugin named in `flakelab.claudePlugins` is enabled as well as installed.
- `setup-wsl-nix.ps1` no longer dies on a native command's stderr (`Invoke-NativeQuiet`).
- An unattended `migrate` writes its completion marker.
- `gitpublisher`'s secret gate survives a large hook report.
- `setup-wsl-nix.ps1` refuses a `#` in the checkout or overlay path and skips a key filename with a single quote.
- The Claude activations that write `~/.claude/settings.json` are gated on `installClaude`.
- `cloneExclude` entries are escaped before reaching `grep`, and a grep failure aborts.
- `flakelab backup --restore` recreates `~/.kube` 0700 with 0600 files, and not under `--dry-run`.
- `path:` flake URLs are percent-encoded, so a path with a space builds.
- `flakelab update` re-locks a `path:` flakelab input before the switch.
- Flow-style YAML lists (`profiles: [a, b]`) are parsed as lists by both overlay generators.
- `gitpublisher` no longer reads pre-commit's "Installing environment" line as a secret finding.

[Unreleased]: https://github.com/tyclab/flakelab/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/tyclab/flakelab/releases/tag/v0.3.0
[0.2.0]: https://github.com/tyclab/flakelab/releases/tag/v0.2.0
[0.1.0]: https://github.com/tyclab/flakelab/releases/tag/v0.1.0
[Keep a Changelog]: https://keepachangelog.com/en/1.1.0/
[Semantic Versioning]: https://semver.org/spec/v2.0.0.html
