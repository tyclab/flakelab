# Contributing

## Dev shell

```bash
nix develop
```

Drops you into a shell with pre-commit, statix, deadnix, shellcheck, zsh, jq
and make — everything the gates below need, at the versions this repo pins.

The flake's outputs — `nixosConfigurations.default`, `.#wslImage`, this dev
shell and every `nix flake check` output — are declared for **`x86_64-linux`
only**, so that is where the gates run. The one part that runs elsewhere is
`files/scripts/nix-overlay-generate` (`flakelab overlay-gen`): a **zsh** script
with no PowerShell and no WSL, so a Linux or macOS host can write an overlay —
and only write one, since applying it needs an `x86_64-linux` NixOS-WSL machine.

## Required local gate

```bash
make test          # the six offline suites, seconds
nix flake check    # the same suites plus statix and deadnix; what CI runs
```

`nix flake check` is the authoritative gate; run `make test` while iterating.

Never run `flakelab test-provision` (or `flakelab build-distro`) casually: each
run imports a distro and wipes WSL interop for every distro in the VM. It
belongs in an expendable session — see [`known-issues.md`](known-issues.md).

## Lint hooks

```bash
make install-hooks   # one-time per clone
make lint            # pre-commit run --all-files
```

Hooks: gitleaks, yamllint, markdownlint-cli2, prettier, shellcheck, `zsh -n`,
ruff-check. `shellcheck` supports sh/bash/dash/ksh only (SC1071), so the
`zsh -n` hook is what covers the zsh scripts under `files/scripts/` — without it
they would be linted by nothing.

## Opening a pull request

- One change per pull request.
- `make test` (or `nix flake check`) green, and `make lint` clean.
- Conventional-commit subjects, matching the repo's history:
  `feat(backup): …`, `fix(scripts): …`, `docs(readme): …`.
- Add a `## [Unreleased]` entry to [`CHANGELOG.md`](CHANGELOG.md) for anything
  user-visible.

## Reporting problems

Bugs and feature requests go to the issue tracker; the templates ask for what
is usually needed. **Security vulnerabilities do not** — see
[`SECURITY.md`](SECURITY.md) for the private channel.

By taking part you agree to the [Code of Conduct](CODE_OF_CONDUCT.md).

## Where things live

The `flakelab` command map lives in
[`ARCHITECTURE.md`](ARCHITECTURE.md#the-cli).

Keep `setup-wsl-nix.ps1` and `templates/overlay/*` **ASCII-only**. Windows
PowerShell 5.1 reads a BOM-less file as ANSI, so a single em-dash mangles into
bytes that terminate a string early — the script then fails to parse before
doing anything, and `init` copies the template through the same reader. Check
with `Select-String -Path setup-wsl-nix.ps1 -Pattern '[^\x00-\x7F]'`.
