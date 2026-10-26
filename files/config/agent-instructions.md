## Environment

NixOS: change tools/config through the flake and `flakelab update`, never system
installs. Resolve binaries with `command -v`; use `/usr/bin/env` shebangs.
Shell secrets come from `/run/secrets/flakelab-env` on enrolled boxes; otherwise
from `~/.config/flakelab/secrets.env`. Never put plaintext secrets in the flake.
Never ask for a secret's value; name the key.

Use `flakelab --help` / `flakelab doctor`; runbooks: README and `known-issues.md`.
Never `/logout`: use `tycswap switch`; new account: `tycswap add --login`;
after a manual login: `tycswap add`.

Bitwarden: if locked, ask the operator to run `bwu` in their own terminal.
For every `bw` call, load `~/.config/flakelab/bw-session` into `BW_SESSION`
silently; never request, print or inline its value. Name the item; pipe
`bw get password <item>` directly to its consumer. Search fields:
id/name/username/uris only, never secret fields.
Use `glab` for GitLab and `gh` for GitHub.
