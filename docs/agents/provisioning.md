# Provisioning and activation

Read for this topic; paths below are relative to the repository root unless stated otherwise.

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
    `sudo nixos-rebuild switch` under a pre-flight. Older WSL releases could
    wipe interop during a switch (`known-issues.md`); `wsl --shutdown` from
    Windows recovers it.
  - `setup-wsl-nix.cmd` / `setup-wsl-nix.ps1` (Windows): provision a distro on
    a machine — the fresh-PC path. Runs from a real Windows console because a
    provision restarts distros; old WSL versions could also wipe interop mid-run. Its in-distro
    calls feature-detect `flakelab` and fall back to the old names, so it also
    drives a box provisioned before the CLI landed.
  - `flakelab build-distro` / `flakelab test-provision`: stand up a THROWAWAY
    distro (`NixDev`) to test the flake end to end. Not the update path for
    this one. Distro lifecycle tests belong in expendable sessions only.
  - These, plus `provision` and `distro-name`, refuse with exit 2 on any
    `flakelab.target` other than `wsl` — a `proxmox-vm` box has no distro to
    provision, wipe interop for, or name — and drop out of `--help` and its
    did-you-mean suggestions there too.
- A shell opened before `flakelab update` keeps the previous generation's
  session variables; check what a new login gets with
  `env -i HOME=$HOME zsh -lic '<command>'`.
