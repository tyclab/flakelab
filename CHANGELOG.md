# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog], and this project adheres to
[Semantic Versioning].

## [Unreleased]

### Added

- `flakelab.claudeAutoMemoryDirectory` (default `null`): asserted into `settings.autoMemoryDirectory`, so Claude Code keeps one auto-memory store for every working directory instead of one per `~/.claude/projects/<slug>`.
- `flakelab doctor` requires Claude Code as the native `~/.local/bin/claude` when the overlay installs it, so a `claude` elsewhere on PATH no longer counts as installed, and warns on a copy in `~/.npm-global/bin`, which comes first on PATH and shadows the native, self-updating one. That copy is never removed; the warning names the `npm -g uninstall`. The reinstall hint for a missing native install passes `claudeAutoUpdatesChannel` (`bash -s <channel>`).
- `flakelab doctor` warns when `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` is set in the environment or in `~/.claude/settings.json`, since it stops Claude Code's self-updater, and, with `claudeRemoteControl` on, when `DISABLE_GROWTHBOOK` is, since that leaves Remote Control unavailable. `DISABLE_TELEMETRY` and `DO_NOT_TRACK` are not findings: they matter to Remote Control only where Trusted Devices is required, and the option's activation removes them anyway. It names the variable, never the value. From Claude Code's own shell the environment's `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` is not read; the secrets file the shell sources is searched for it instead.
- With `installCodex`, `~/.codex/AGENTS.md` gets a `<!-- BEGIN managed by flakelab -->` block like `~/.claude/CLAUDE.md`: the shipped distro facts, the target facts and `claudeMdExtra`, so Codex works from the same rules as Claude Code. Text outside the markers stays; a symlink there becomes a regular file. The block leaves out Claude's permission tiers and the question-tool text, which Codex already receives through `developer_instructions`. `$CODEX_HOME` counts only when the activation environment sets it, and an `AGENTS.override.md` beside the file makes Codex read that instead. A `home.file` for the same path, such as Home Manager's `programs.codex.context`, fails the build with a pointer to `claudeMdExtra`.
- A managed block that cannot be written, or whose path links into the Nix store, is a warning instead of an aborted activation.
- `flakelab-prune` removes `~/.platformio` and `~/.cache/huggingface` once nothing in them was written for 30 days and no running process executes from or holds a file in them; the next firmware build or embedding run downloads what it needs again.
- `gitcleaner` reports a checkout parked on a landed branch — HEAD, or a linked worktree, on a branch that was pushed, merged and deleted on the remote — instead of skipping it without a word, and `--json` lists it under `parked`. At a terminal it offers to switch the checkout to the default branch (or remove the worktree) and delete the branch; `--unpark` does the same under `--yes`. Uncommitted changes, untracked files in a worktree, and a worktree lock that names no pid or a running one leave the checkout alone.

### Changed

- The managed `~/.claude/CLAUDE.md` and `~/.codex/AGENTS.md` blocks tell an agent never to ask for a secret's value, and to name the key instead.
- Shared Claude/Codex instructions keep environment and safety rules concise; CLI manuals and repeated question-tool explanations stay in their reference documentation.
- `flakelab doctor` no longer warns on every local flakelab override. A `path:` or `git+file:` input is a finding only when its checkout has uncommitted changes to tracked files, is behind its tracking ref as last fetched (the doctor fetches nothing and takes no index lock), or is missing. An overlay with no `flake.lock` and a `path:` input in `flake.nix`, the state `setup-wsl-nix.ps1` leaves on purpose, is read from `flake.nix` instead of being reported as unknown.
- The question tool guidance now requests self-contained questions and short action choices, so the decision does not depend on background text hidden by terminal previews. Optional detail remains in the Home Assistant inbox.
- The `ask_question` text, its field descriptions and the managed CLAUDE.md and Codex instructions say what each surface shows: the terminal dialog three lines, the phone and watch push the question with a button for each of one or two options, the context in full only in the inbox record. The question's first line names the decision and the recommendation, options stay near 40 characters, and two are preferred. "Include enough context to answer from the phone" and "Relevant details the user needs to decide" are gone: they put the choice in the context, which neither the dialog nor the push showed.
- The terminal dialog puts the context, wrapped like the question, directly under the options: the blank line before it took the third of the three lines Claude Code shows.
- Claude's permission-tier section moved from `files/config/agent-instructions.md` to `files/config/claude/auto-mode.md` and now follows the target facts in `~/.claude/CLAUDE.md`; its text is unchanged.
- The `claudeAutoMode` force-push rule also accepts a lease with an explicit sha, `git push --force-with-lease=<branch>:<expected-sha> origin <branch>`, which it refused even when the operator named it: git ignores `--force-if-includes` beside an explicit sha, so the required flag added nothing to the strictest spelling. The rule now covers any branch that is neither protected nor the default branch, not only the agent's own.
- `flakelab update` reports a `path:` flakelab input's re-lock as information rather than a warning: an overlay generated from a checkout is `path:` by design, so the warning came on every run.
- `gitclean` deletes under `~/git` only; `gitcheck` still reports across `extraReposDirs` as well. Both aliases had the same roots, so the deleter reached the trees `extraReposDirs` exists for, whose clones are kept nowhere else. `gitcleaner --repos-dir <dir>` still covers one of them on demand.
- Git starts a new repository on `main` (`init.defaultBranch`, a default an overlay's own `programs.git.settings.init.defaultBranch` overrides). Unset, `git init` named it `master` and printed its hint each time, and `git config --global` cannot add it, since `~/.gitconfig` is managed by the flake.

### Fixed

- Update tycswap to v0.7.26 so backspace in its terminal account form removes a complete Unicode character.
- `gitcleaner` keeps local commits added after a branch's MR or PR merged. Squash-merge cleanup requires the merged source SHA to match the local tip, and cleanup rechecks that tip after forge queries or confirmation before removing a checkout or branch. A refused deletion also returns a failure exit code in JSON mode.
- `flakelab update` no longer reports `flakelab input unchanged` when the GitHub lookup failed. `nix flake update` exits 0 on a failed lookup and re-locks to Nix's last cached answer; the update now says the input was not checked and prints Nix's reason. The `--refresh` added for this in #279 is gone: `nix flake update` already re-checks the branch on every run.
- `flakelab sessions --open` no longer resumes a session that is still running, which started a second process appending to the same transcript; run twice, it doubled every session. A running session in the `agents` server gets a tab on its window unless a client already shows that window, and one running anywhere else is named and left alone.
- `flakelab clone` with GitLab groups and no `GITLAB_TOKEN` exits 3 before listing anything and names where the token goes: the sops secrets file on an enrolled box, `~/.config/flakelab/secrets.env` otherwise. `setup-wsl-nix.ps1 provision` no longer sources `secrets.env` itself before the clone (`.zshenv` does, and an enrolled box must not read the fallback file), stays quiet on that refusal, and calls a missing key or `secrets.env` steps that wait rather than a distro "built but unconfigured".
- The `sopsSecretsFile` option text no longer claims a fallback to `secrets.env` that the zsh init deliberately does not make.
- `flakelab doctor`, `gitchecker` and `gitcleaner` name the sops secrets as the token source too, not `secrets.env` alone, and doctor no longer says the secrets are read only at login.
- A Codex CLI install or update that cannot fetch its installer puts curl's own error (a 404, an unresolvable host) in the deferral instead of guessing "offline?", and one whose installer fails says that.
- A marketplace that `flakelab update` cannot refresh shows Claude's own error, and the warning says so instead of guessing "offline, or no agent key"; a marketplace the activation cannot add says its error precedes the deferral in the activation log instead of guessing "(offline?)".
- A first Claude Code install runs the official installer with `claudeAutoUpdatesChannel` (`bash -s latest`, say), so it starts on the channel the settings assert; without it the installer put `stable` on the box and a `latest` box only got there at its next self-update.
- `setup-wsl-nix.ps1 provision` keeps the distro running across its closing `flakelab clone` and loads the SSH key into its agent again right before it. WSL can stop the distro between two `wsl.exe` calls, which took the agent and its unlocked key with it, so the clone refused on an empty agent and the provision closed with an empty `~/git`. A key that cannot be loaded is a warning and the clone still runs: an unencrypted key needs no agent, and a passphrase-protected one makes the clone refuse with its own message.

### Removed

- The Synology MCP: `SYNOLOGY_PASSWORD` and `SYNOLOGY_DEVICE_ID` are no longer asked for or harvested (`setup-wsl-nix.ps1` lists them as retired, and the overlay generator still keeps them out of the store), and the examples drop every `SYNOLOGY_*` key.
- The wslkube migration path: `setup-wsl-nix.ps1 migrate`, `-WslkubeDistro`, `-WslkubeInstance`, the sibling wslkube checkout as the default `-Config`, the private-key pull from a running wslkube distro, and the `.migrated-from-wslkube` marker; `flakelab overlay-gen --wslkube` and its `variables.yaml` layering; `flakelab backup --restore --from` reading a `files/config/` layout (a payload root with `shared/` or `instances/` still works). `-Config` now defaults to `<overlay>-payload\user_data.yaml` only. The v0.4.0 tag keeps the old path for a box that still needs it.
- `dockerautostart` and `extra_task_files` are no longer config keys: a config carrying one is told it maps to nothing, like any other unmapped key.
- The fallback to a pre-rename `wslnix-config` overlay.

### Security

- Both overlay generators (`flakelab overlay-gen` and `setup-wsl-nix.ps1 generate`/`provision`) withhold a `custom_env_vars` entry from the generated `flake.nix` when its name looks like a credential, not only when it is one of the secret names the example config ships: `TOKEN`, `SECRET`, `PASSWORD`, `PASSWD`, `APIKEY` or `CREDENTIAL` as a whole `_`-separated word, or `API_KEY` or `PRIVATE_KEY` anywhere, in any case. Before, a credential named any other way, `SERVICE_API_TOKEN` say, was written into the tracked `flake.nix` and from there into the world-readable nix store. A name ending in `_URL`, `_DIR`, `_FILE`, `_PATH`, `_HOST` or `_NAMESPACE` stays a session variable unless it names a webhook (`SLACK_WEBHOOK_URL`), whose URL is the credential, as do `MAX_THINKING_TOKENS` and `GOOGLE_APPLICATION_CREDENTIALS`, where the word is only part of one. The run names each withheld entry, never its value, and `provision` copies the values into `secrets.env` with the named tokens, so none is lost.
- `flakelab update` reads `recommended-permissions.json` and `recommended-ask.json` only from a marketplace `claudePluginMarketplaces` declares, not from any clone under `~/.claude/plugins/marketplaces`, and refuses a file that is not a list of rule strings or an allow rule that approves every use of `Bash`, `PowerShell`, `Write`, `Edit`, `MultiEdit`, `NotebookEdit` or `WebFetch`.

## [0.4.0] - 2026-10-22

### Added

- `flakelab.pruneSchedule` (default `weekly`): `virtualisation.docker.autoPrune` (unused images, stopped containers and build cache older than a week) and the `flakelab-prune` user timer (Codex releases other than the current one and those a running process still executes from, `uv cache prune`, `pre-commit gc`); null schedules none.
- `flakelab.sopsKeyFiles`: render variables written to their own owner-only files after every render (`flakelab-sops-key-files.service`) and left out of the shell environment, for MCP headers helpers; a null entry is only left out.
- `flakelab.claudeDeniedMcpServers`: Claude Code's `deniedMcpServers`, by name, claude.ai connectors included.
- A server named in both `claudeMcpServers` and `claudeMcpDisabledServers` is written to `~/.config/flakelab/claude-mcp/<name>.json` for `claude --mcp-config`; a `codexSettings.mcp_servers` entry merges over a `codexMcpSources` one, so `enabled = false` turns it off; `flakelab mcp doctor` checks helper-configured endpoints by running the helper.
- `flakelab sessions --start claude --group fable|opus` selects a tycswap rotation group; discovery and recovery snapshots preserve the profile and actual continuation id. Explicit group selection on `--resume` / `--open` moves older conversations through tycswap's native fork. Tmux launches forward validated handover context and clear stale handover markers on ordinary starts. `session-groups.md` explains account capability, group recovery and reviewed handover workflows.
- `flakelab.tycswapAppPort`: `tycswap app --headless --port <n>` as the user service `flakelab-tycswap-app`, the dashboard the Windows tray (`tycswap.exe app --remote`) drives through WSL2's localhost forwarding; the tray is registered once per PC with `--autostart on`. Null, the default, installs no service.
- `flakelab doctor` has a "Dashboard" section: it warns when `flakelab-web.service` still runs a previous generation's code after `flakelab update` (activation never restarts it) and names the restart, and when the unit is loaded but down.
- `flakelab.boxName`: a second box built from the same overlay that keeps the shared hostname names itself here, and that name — not the hostname or the distro name — becomes its backup payload instance (`instances/<name>`), its slug manifest in the state root and the gate ledger's `host`. Before, two such boxes wrote one instance and one manifest through the sync, and a ruling taken on one counted as the other's. Null keeps everything on the distro name and the hostname, as before.
- Opt-in GitHub discovery for `flakelab clone`: `cloneGithub` defaults off, and `githubOwners` selects users or organizations (empty means the authenticated account and its organizations). Paginated discovery skips archived, disabled and empty repositories, honors `cloneExclude`, and uses the existing `gh` credentials.
- `flakelab web`: a browser dashboard for the tycswap logins and the sessions on 127.0.0.1:8321 behind a token; `flakelab.web.enable`, `flakelab.web.terminal` (ttyd), `flakelab.web.logo`.
- `flakelab.stateSyncthing`: the state root replicated by Syncthing through an untrusted hub; needs a Linux `stateRoot` and `sopsSecretsFile`.
- A bare `flakelab` opens a menu, and a command missing an argument asks for it at a terminal; `FLAKELAB_NO_PROMPT=1` turns every prompt off.
- `flakelab.mcpBrowsers.headless`: a `playwright-headless` MCP server in Claude and Codex on any target.
- `flakelab.mcpShared` and `flakelab mcp` (`connect`, `login`, `status`, `import-codex`): OAuth MCP accounts shared by Claude and Codex, one credential host; a refusal (unknown or `login-required` account, wrong host, an overwriting `import-codex`) exits 2.
- `flakelab notify`: an ntfy push when an agent session waits (`NTFY_URL`, `NTFY_TOKEN`); `flakelab.notify.enable` and `flakelab.notify.events` write the hook; a bare run at a terminal prints its usage.
- `flakelab notify` also posts to a JSON webhook, `NOTIFY_WEBHOOK_URL` (Home Assistant's `/api/webhook/<id>`), beside or instead of ntfy: `{"title", "message", "priority", "tags"}` with the full message. Neither URL is put on a command line, in `--dry-run` output or in an error. A target missing from the environment is read from the sops render `/run/secrets/tyc-env` before `~/.config/tyc/secrets.env`, so `sopsKeyFiles.NOTIFY_WEBHOOK_URL = null` keeps the webhook URL out of the shell.
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

- The fallback secrets file is `~/.config/flakelab/secrets.env` and the sops render `/run/secrets/flakelab-env`; `bwu` keeps the Bitwarden token in `~/.config/flakelab/bw-session`. Nothing moves an existing `~/.config/tyc` for you: `flakelab doctor` warns about it and prints the `mv`. An overlay that names `/run/secrets/tyc-env` or a `~/.config/tyc` path (`sopsKeyFiles`, scripts) changes with it.
- The stale-clone report prints a `rm -rf` line per clone it found safe to remove, and tells a kept one that its work exists only locally, instead of suggesting a `~/.stale-repos` parking directory that nothing ever swept.
- pre-commit comes from nixpkgs-unstable, which ships the 4.6.2 the overlay pinned by hand, so Renovate's lock maintenance moves it from now on; the overlay keeps only the installer patch. Python hooks reinstall once per box under its Python 3.14.
- Tycswap is pinned to v0.7.19: the Windows tray separates each table from its details with a divider line and frames the detail text.
- Tycswap is pinned to v0.7.18: the Windows tray switches by double-click with a destination confirmation, and the panel sizes everything from its font, so columns, buttons and tabs fit their text.
- Tycswap is pinned to v0.7.17, adding a compact tray overview and shared settings for the default, Fable and Opus/other scopes in both tray and web. Flake-managed automation remains separate from editable runtime policy.
- Tycswap is pinned to v0.7.16, adding independent Fable and Opus/other groups, native conversation migration and reviewed cross-provider handover.
- Tycswap is pinned to v0.7.11: in Git Bash the API-key switch prompt reads the typed answer, background Claude Code checks on Windows open no console window, `run` refuses a `claude.cmd`-incompatible argument before preparing the session, and a credential that differs from its backup only in encoding no longer reads as foreign. In v0.7.10 `tycswap run` and `tycswap env` drop `CLAUDE_SECURESTORAGE_CONFIG_DIR`, so a pinned session can no longer read or overwrite the live login. In v0.7.9 a switch also holds Claude Code's storage-write lock and waits out its credential-refresh lock for 60 s, so an MCP login saved or a token refreshed mid-switch is no longer lost or overwritten; Ctrl-C releases those locks; `add --login` leaves no login keys behind; slot backups keep only the account part; `status` and `list` report a busy store; `tycswap app` uses the system proxy on macOS and Windows; and two Windows "Access is denied" races are fixed. v0.7.8 keeps `statusline.json` in its store, each account's label and last measured quota keyed by email and organization, so a Claude Code status line can show the live account and its quota without running tycswap. In v0.7.7, on Windows, `add --login` and `tycswap run` started an npm-installed Claude Code from a path with a space when an argument also held one, and a Ctrl-C while the tray app started ended it. In v0.7.6 the Windows tray icon came back after Explorer restarts, and the tray app and a command logging at once stopped writing into a rotated-away log or, on Windows, blocking its rotation. v0.7.3 to v0.7.5 brought the model windows beside their bar, storage transactions that own their lock, and persistent model controls. v0.7.2 made `tycswap web` and `tycswap app` end with 0 on Ctrl-C as on SIGTERM, with their cleanup run (the app removes its remote token file; v0.7.1 had fixed SIGTERM alone). v0.7.1 made a Codex remove or disable hold the Codex store lock (a remove during a usage refresh of the same account could leave a live credential file behind) and a busy Codex store a lock error (409 on the dashboard) for every Codex verb. v0.7.0 brought `tycswap app`, the dashboard as a menu-bar or notification-area application, `tycswap upgrade` replacing a release binary in place, `tycswap app --remote` as a Windows tray for the app in a WSL distro, Codex accounts in the dashboard and the tray, and API-key accounts with a base URL.
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

- `gitchecker` lists a repo whose project the forge says is gone (GitLab's "could not be found or you don't have permission", GitHub's "Repository not found", a missing repository path) as `skipped: remote gone` and goes on with the sweep, as it already did for a repo with no origin or an unsupported host; such a repo is attention, never "current", and its local state is still checked. One deleted project anywhere under a root aborted every run, so the sweep never reported. A network failure or a timeout still aborts. `--json` gives every repo a `skipped` field, the reason for any skip (no origin, unsupported host, remote gone) or null.

- `flakelab backup` drops a globbed file from the payload once it is deleted at home (`~/.kube/kubeconfig_*`, `cert-*`, `ca-*`, `~/.config/glab-cli`, `~/.config/helm`), as directories already did: the copies stayed for good, so a restore or a migration brought deleted kubeconfigs and their client certificates back. `--dry-run` names each removal; the shared `ssh/keys` stays additive, a missing source directory removes nothing, and a name still at home keeps its copy even as a link whose target is not mounted or spelled in another case (the payload may sit on NTFS).

- An interactive zsh keeps the `KUBECONFIG` it inherits and appends each `~/.kube/*.yaml` it does not already list, starting from `~/.kube/config` only when none is set. It replaced the variable outright, so a `sessionVariables.KUBECONFIG` from the overlay was lost in every interactive shell, and each run left a trailing `:`.

- Backups accept an empty `.git` marker created by workspace tools. Actual repositories, Git files, symlinks and unreadable metadata still prevent shared-state writes.

- On WSL, `flakelab-state-sync` and `flakelab-backup` no longer depend on Windows interop to learn the distro name. A systemd unit has no `WSL_DISTRO_NAME`, so both asked `wsl.exe`, which hangs on a unit's dead interop socket until its timeout, and both failed on every run. Every interactive shell now records the name under `~/.local/state/flakelab/distro-name`, and `flakelab distro-name` reads that before asking Windows.
- `flakelab clone` no longer aborts its stale-clone report, and so `update-all`, on one stalled GitLab request: the group listing retries a timeout, a reset or a hung TLS handshake twice, one and two seconds apart; a status error such as 401 still fails at once.
- A commit whose pre-commit hooks still had to install a node hook no longer has its index overwritten. pre-commit ran npm with the commit's `GIT_INDEX_FILE`, and npm's clone of the hook wrote the hook repository's index over it: under `git commit -a` the commit aborted with `fatal: unable to read` and an object id, and in a linked worktree the worktree's own index was left holding the hook's files. The distro's pre-commit now gives every hook installer the environment it already gives its own clones, without the commit's `GIT_*` variables.

- `flakelab doctor` shows the "Native MCP clients" section only when there is a native server to check or the check fails. A box that declares no Codex bearer-token endpoint, including every box with `installCodex = false`, passed an empty check and printed "native MCP files and credentials agree" for nothing.

- `flakelab update` finds the clone it counts the flakelab input's commits in with `find` instead of a six-level zsh glob, which followed symlinked `node_modules` farms and took 5 to 8 minutes on a full `~/git`; the search now takes about a second, skips hidden directories and does not follow symlinks.

- `flakelab sessions --save` succeeds with exactly one session and replaces snapshots atomically using sync-excluded temporary files. Discovery includes version-named Claude processes and every user conversation held by a shared Codex server, using each rollout's directory and excluding daemon supervisors and internal subagents. Machine-specific save names and cross-instance resume/pruning isolation are preserved.

- Protect timer-owned tycswap auto-switch: the dashboard service declares its scheduler, so tray/dashboard starts and remembered startup cannot launch a second engine. Update tycswap to 0.7.5 with persistent Off/All/Selected model controls, stale-save protection, and accurate selected-window tray gauges.

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
- `flakelab update` no longer re-fetches the Claude marketplaces its switch's activation just fetched, nor warns "not refreshed" over them.

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

[Unreleased]: https://github.com/tyclab/flakelab/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/tyclab/flakelab/releases/tag/v0.4.0
[0.3.0]: https://github.com/tyclab/flakelab/releases/tag/v0.3.0
[0.2.0]: https://github.com/tyclab/flakelab/releases/tag/v0.2.0
[0.1.0]: https://github.com/tyclab/flakelab/releases/tag/v0.1.0
[Keep a Changelog]: https://keepachangelog.com/en/1.1.0/
[Semantic Versioning]: https://semver.org/spec/v2.0.0.html
