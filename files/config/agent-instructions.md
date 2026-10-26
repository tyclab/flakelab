## Environment

NixOS, managed by the flakelab flake. Change tools/config through the flake and
`flakelab update`, never system installs. Resolve binaries with `command -v`;
use `/usr/bin/env` shebangs.
Secrets come from the shell's sops render `/run/secrets/flakelab-env`, falling
back to `~/.config/flakelab/secrets.env`; never plaintext in the flake.

Use `flakelab --help` and `flakelab doctor`; runbooks are in README and
`known-issues.md`. Never `/logout`: use `tycswap switch`,
`tycswap add --login` for a new account, and `tycswap add` after a manual login.

Bitwarden: if locked, ask the operator to run `bwu`; never request or inline a
session token. Name the vault item; pipe `bw get password <item>` directly to its
consumer. Filter item searches to id/name/username/uris, never secret fields.
Use `glab` for GitLab and `gh` for GitHub.
