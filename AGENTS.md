# AGENTS.md — flakelab

Shareable NixOS dev environment (`nixosConfigurations.default` — the WSL distro
— `nixosConfigurations.proxmox-vm`, `.#wslImage`, `.#proxmoxImage`,
`lib.mkSystem`).
`nix/users/default.nix` ships neutral placeholders; real personal values live in
the private overlay `flakelab-config`, which imports this flake via
`lib.mkSystem`.

- Secrets come from OpenBao via `~/.config/tyc/secrets.env` at use time.
- The Bitwarden session token is the exception: `bwu` takes the Bitwarden master password, parks the token in `~/.config/tyc/bw-session`, and the shell exports it as `BW_SESSION`. A locked vault waits on `bwu` — never ask for the token or put it on a command line.
- **`flakelab` is the CLI.** One binary, subcommands; `flakelab --help` lists
  them all. It is a ROUTER (`files/scripts/flakelab`): each subcommand still
  execs the same per-command wrapper `nix/scripts.nix` builds, so every one
  keeps its own pinned PATH and exported environment
  (`FLAKELAB_REPO_ROOT` from `repoPath`, `FLAKELAB_BACKUP_ROOT`,
  `FLAKELAB_STATE_ROOT` from `stateRoot` when set, `FLAKELAB_KIRO_PLUGIN_*`).
  `nix/cli.nix` assembles the wrappers into the
  dispatch dir the router reads.
  - Renamed, old name gone from PATH: `update` (was `nix-update`),
    `update-all`, `doctor`, `backup`, `provision`, `clone`
    (was `nix-clone-repos`), `overlay-gen`, `build-distro`
    (was `build-dev-wsl-nix`), `test-provision`, `distro-name`
    (was `get_current_wsl_distro_name`), `clone-repos`, `activate-hooks`,
    `stale-repos` (was `report-stale-repos`), `glab-projects`.
  - `sessions` (`claude-sessions`, the script name kept): the running agent
    sessions — Claude Code, Codex, Kiro CLI — with their session ids: Claude
    Code's from its own registry `~/.claude/sessions/<pid>.json` (open
    transcript in `/proc` as fallback), Codex's from the rollout file the
    process holds open, Kiro's from `~/.kiro/sessions/cli/<id>.json` (the
    locked entry in the process's directory). `--start <tool> [dir] [-- args]`
    runs one in a window of the `agents` tmux session so it outlives its
    terminal; `--attach [id|window]` joins it (a grouped view session per
    terminal); the table's HOST column names the window. `--save` before a
    `wsl --shutdown` or reboot, `--resume` prints each tool's resume command
    after (`claude --resume`, `codex resume`, `kiro-cli chat --resume-id`),
    `--open` puts each in its own Windows Terminal tab — attached to a tmux
    window when tmux is on PATH, so the tab can close. `--autosave` (the
    `flakelab-sessions-autosave` timer, `sessionsAutosaveInterval`) keeps one
    snapshot per boot, so a crash needs no `--save` beforehand; `--recent`
    lists stopped sessions changed in the last day. Never `pgrep -f`: that
    matches helpers. Saved lines are `<tool>  <dir>  <id>`; a line without the
    tool column is Claude Code. Saves go to the state root's `claude/sessions/`
    when one is set, else `~/.local/state/flakelab/sessions/`, never into
    `~/.claude/sessions`.
  - `accounts` (new, `accounts`): several logins per agent CLI, one live
    per tool. `add <tool>` snapshots the live login into
    `~/.local/state/flakelab/accounts/<id>/` (never reused ids; alias, label
    or id name an entry), `switch <entry>` makes it the live login inside one
    transaction under our flock and the tool's own locks (Claude Code: the
    `~/.claude.lock` / `~/.claude.json.lock` mkdir protocol; a held lock
    refuses with exit 2 and changes nothing), writing the outgoing login back
    into its entry first (it may hold a rotated refresh token) or into
    `unclaimed/` when no entry carries it. `--next <tool>` rotates; `alias`,
    `disable`/`enable`, `remove --yes`, `status [--json]`. Phase 1 ships the
    Claude Code adapter (`files/scripts/lib/accounts-claude.zsh`).
    `auto [--once] [--dry-run] [--json]` is the engine
    (`files/scripts/lib/accounts-auto.jq`, pure jq over one document, the
    headroom defs shared with the script in `lib/accounts-headroom.jq`) that
    switches before a limit; `flakelab.accounts.autoSwitchInterval` schedules
    it, the other `flakelab.accounts.*` options set its bars. `run <entry>
[-- args]` and `env <entry> [--shell sh|fish|pwsh]` give an entry a
    profile of its own (`profiles/<id>/`, `CLAUDE_CONFIG_DIR`) beside the
    live login; an entry with a running profile session is never switched
    onto or targeted. Adapters: Claude Code, Codex (`lib/accounts-codex.zsh`:
    `auth.json` whole, refuses a switch while a `codex` runs unless
    `--force`, usage through `codex app-server`) and Kiro
    (`lib/accounts-kiro.zsh`: rows of the SQLite store swapped in one
    transaction, one monthly window the engine never counts). The adapter
    contract, usage and the engine's rules are in `accounts.md`. The store
    rides `flakelab backup` (`accounts/`); `flakelab doctor` has an
    `Accounts` section; `ingest` takes the statusline's `rate_limits`.
  - `notify` (new, `notify`): a push to an ntfy topic when a session waits
    on you; the Claude Code `Notification` hook (`flakelab.notify.enable`)
    and Codex's `notify` hook call it, `--message` sends one by hand.
    `NTFY_URL`/`NTFY_TOKEN` from `secrets.env` at use time; a hook run never
    fails its caller. Remote reach: `flakelab.mosh.enable` on the VM,
    `files/config/windows/enable-openssh-host.ps1` for a WSL host, both over
    WireGuard (`remote-sessions.md`).
  - `web` (new, `web`): the dashboard in a browser (`lib/web.py`, python3
    stdlib; `files/config/web/index.html`): the logins with their windows
    and a switch button, the sessions, a start form, the engine's dry run,
    over `accounts` and `claude-sessions` as CLI calls. 127.0.0.1:8321 and
    a bearer token from `~/.local/state/flakelab/web/token` (`--print-token`);
    `flakelab.web.*` runs it as a user service, `web.terminal` adds ttyd on
    the `agents` tmux session with the same token.
  - `gitchecker`, `gitcleaner`, `gitpublisher` stay STANDALONE commands — no
    namespace collision, and other repos and skills invoke them by name.
  - Seven deprecation shims still answer to the old names — `nix-update`,
    `nix-doctor`, `nix-backup`, `nix-provision`, `nix-clone-repos`,
    `build-dev-wsl-nix`, `test-provision-nix`: one line to stderr, then exec.
    They go away next release. Write the `flakelab` form in
    new code. The other seven old names are simply gone.
  - Each subcommand's own `--help`, flags, exit codes and `--json` output are
    unchanged, including the script name the usage text prints
    (`flakelab update --help` still says `nix-update [--all]`).
- **What to run** — four different jobs, often conflated:
  - `flakelab overlay-gen` (zsh; Linux and macOS, no PowerShell and no WSL):
    write the private overlay from a `user_data.yaml`. It scaffolds; it never
    provisions or rebuilds. It reads `templates/overlay/` and `profiles/`
    relative to itself, so which copy you run matters:
    `./files/scripts/nix-overlay-generate` from a checkout reads THAT
    checkout and defaults `--flakelab-ref` to `path:` it — that is still the
    BOOTSTRAP path, and the one to use when editing the templates. From PATH
    it reads the installed flake generation and `--flakelab-ref` is
    **required**, because the only value it could default to is a frozen,
    GC-able `/nix/store` path; it refuses rather than write that into an
    overlay you would then be pinned to.
  - `flakelab update`: update THIS distro to the current flake + overlay.
    `sudo nixos-rebuild switch` under a pre-flight. A switch from
    inside the running distro completed with interop intact on 2026-08-20;
    the wipe remains a documented historical hazard (`known-issues.md`), and
    `wsl --shutdown` from Windows recovers it.
  - `setup-wsl-nix.cmd` / `setup-wsl-nix.ps1` (Windows): provision a distro on
    a machine — the fresh-PC path. Runs from a real Windows console because a
    provision restarts distros and can wipe interop mid-run. Its in-distro
    calls feature-detect `flakelab` and fall back to the old names, so it also
    drives a box provisioned before the CLI landed.
  - `flakelab build-distro` / `flakelab test-provision`: stand up a THROWAWAY
    distro (`NixDev`) to test the flake end to end. Not the update path for
    this one. Interop-wiping — expendable sessions only.
  - These, plus `provision` and `distro-name`, refuse with exit 2 on any
    `flakelab.target` other than `wsl` — a `proxmox-vm` box has no distro to
    provision, wipe interop for, or name — and drop out of `--help` and its
    did-you-mean suggestions there too.
- Docs live in the repo root — no `docs/` folder; every `.md` sits at the top level.
- `gitchecker` (report) and `gitcleaner` (delete) both take `--repo <path>` and
  `--json`, so use those rather than parsing the human report: one document on
  stdout, abort included. To remove a branch, take the plan from
  `gitcleaner --repo . --json` and act with `--only <branch> --yes` — never
  `--yes` alone, which sweeps every repo it can reach.
- `gitpublisher` publishes the working tree as an MR (branch, commit through
  the hooks, push, open or update) and holds those gates itself — `--json` for
  the result, exit 1 for a gate stop, 2 for a refusal. It opens; it never merges.
  `--title` is the MR title; pass `--message-file FILE` when the commit needs a
  body, because `--title` alone is the whole message.
- Changing any of these means running its offline suite. `make test` runs all
  fifteen (`test-clone-repos`, `test-gitchecker`, `test-gitcleaner`,
  `test-gitpublisher`, `test-nix-backup`, `test-nix-overlay-generate`,
  `test-flakelab-cli`, `test-claude-sessions`, `test-accounts`, `test-nix-update`,
  `test-nix-doctor`, `test-switch-result`, `test-xdg-open`, `test-notify`, `test-web`) and stays the
  required local gate. These are TEST HARNESSES, not user commands,
  so the `flakelab` CLI did not rename them: `test-nix-backup`,
  `test-nix-doctor` and `test-nix-overlay-generate` keep the old prefix on purpose, because renaming
  them would drag `Makefile` and `flake.nix`'s `checks.<system>.*` along for no
  change in behaviour. They run the scripts by path, not by command name. CI
  runs the same fifteen as flake checks — `nix flake check` (the `test` job)
  builds
  `checks.<system>.{clone-repos,gitchecker,gitcleaner,gitpublisher,nix-backup,`
  `nix-overlay-generate,flakelab-cli,claude-sessions,accounts,nix-update,nix-doctor,switch-result,xdg-open,notify,web,statix,deadnix}`,
  so a red suite blocks the pull
  request rather than surviving to main. Those checks copy the WHOLE tree
  into the sandbox, not just `files/scripts/` — `test-nix-overlay-generate`
  asserts against the tracked `templates/overlay/` and
  `files/config/user_data.example.yaml`.
