# AGENTS.md — flakelab

Shareable NixOS dev environment (`nixosConfigurations.default` — the WSL distro
— `nixosConfigurations.proxmox-vm`, `.#wslImage`, `lib.mkSystem`).
`nix/users/default.nix` ships neutral placeholders; real personal values live in
the private overlay `flakelab-config`, which imports this flake via
`lib.mkSystem`.

- Secrets come from OpenBao via `~/.config/tyc/secrets.env` at use time.
- The Bitwarden session token is the exception: the operator runs `bwu`, which parks it in `~/.config/tyc/bw-session`, and the shell exports it as `BW_SESSION`. A locked vault means asking the operator to run `bwu` — never asking for the token or putting it on a command line.
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
  six (`test-gitchecker`, `test-gitcleaner`, `test-gitpublisher`,
  `test-nix-backup`, `test-nix-overlay-generate`, `test-flakelab-cli`) and
  stays the required local gate. These are TEST HARNESSES, not user commands,
  so the `flakelab` CLI did not rename them: `test-nix-backup` and
  `test-nix-overlay-generate` keep the old prefix on purpose, because renaming
  them would drag `Makefile` and `flake.nix`'s `checks.<system>.*` along for no
  change in behaviour. They run the scripts by path, not by command name. CI
  runs the same six as flake checks — `nix flake check` (the `test` job)
  builds
  `checks.<system>.{gitchecker,gitcleaner,gitpublisher,nix-backup,`
  `nix-overlay-generate,flakelab-cli,statix,deadnix}`, so a red suite blocks the pull
  request rather than surviving to main. Those checks copy the WHOLE tree
  into the sandbox, not just `files/scripts/` — `test-nix-overlay-generate`
  asserts against the tracked `templates/overlay/` and
  `files/config/user_data.example.yaml`.
