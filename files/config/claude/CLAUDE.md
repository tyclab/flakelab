## Environment

This is a **NixOS** box provisioned from the `flakelab` flake — not managed by `apt`.
Tools come from the flake, so `/usr/bin` holds almost nothing and shebangs other than `/usr/bin/env` are unreliable: resolve binaries with `command -v`.
Change the environment by editing the flake and running `flakelab update`, never by installing into the system.
Secrets are not in the flake in plaintext: the shell env carries them, sourced from the sops-nix render at `/run/secrets/tyc-env` when this box is enrolled, else from OpenBao via `~/.config/tyc/secrets.env`.

## Permissions and auto mode

Reference: <https://code.claude.com/docs/en/auto-mode-config.md>. The tier order this flake writes is in AUTO-MODE.md.

`permissions.deny` and `permissions.ask` are both evaluated before the classifier and neither can be cleared by it: a deny rule never prompts, an ask rule always prompts. Destructive-but-legitimate work therefore belongs in `autoMode.soft_deny`, which a message naming the operation and its target clears — putting it in `deny` or `ask` revokes that.

## The CLI

`flakelab --help` lists every distro command available on this target.
`flakelab doctor` diagnoses a provisioned distro and says what to run, so prefer it over guessing at broken state.
`flakelab backup` archives the host-specific seed (secrets, keys, tool config) beside the overlay, and `--restore` puts it back.
