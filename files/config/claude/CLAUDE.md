## Environment

This is a WSL2 **NixOS** distro provisioned from the `flakelab` flake — not Ubuntu, and not managed by `apt`.
Windows drives are mounted at `/mnt/c/`, `/mnt/d/`.
Tools come from the flake, so `/usr/bin` holds almost nothing and shebangs other than `/usr/bin/env` are unreliable: resolve binaries with `command -v`.
Change the environment by editing the flake and running `flakelab update`, never by installing into the system.
Secrets are not in the flake: they come from OpenBao via `~/.config/tyc/secrets.env` and reach tools through the shell env.

## The CLI

`flakelab --help` lists every distro command.
`flakelab doctor` diagnoses a provisioned distro and says what to run, so prefer it over guessing at broken state.
`flakelab backup` archives the host-specific seed (secrets, keys, tool config) beside the overlay, and `--restore` puts it back.

## Provisioning

`flakelab build-distro` and `flakelab test-provision` drive distro lifecycle from the host side and wipe host WSLInterop.
Never run them from a session that needs interop, and never run `wsl --shutdown` or `wsl --terminate` — hand back to the operator.
