## Environment

This is a **NixOS** box provisioned from the `flakelab` flake — not managed by `apt`.
Tools come from the flake, so `/usr/bin` holds almost nothing and shebangs other than `/usr/bin/env` are unreliable: resolve binaries with `command -v`.
Change the environment by editing the flake and running `flakelab update`, never by installing into the system.
Secrets are not in the flake in plaintext: the shell env carries them, sourced from the sops-nix render at `/run/secrets/tyc-env` when this box is enrolled, else from `~/.config/tyc/secrets.env`, which the operator fills from their secret store.

## Permissions and auto mode

Reference: <https://code.claude.com/docs/en/auto-mode-config.md>. The tier order this flake writes is in AUTO-MODE.md.

`permissions.deny` and `permissions.ask` are both evaluated before the classifier and neither can be cleared by it: a deny rule never prompts, an ask rule always prompts. Destructive-but-legitimate work therefore belongs in `autoMode.soft_deny`, which a message naming the operation and its target clears — putting it in `deny` or `ask` revokes that.

## The CLI

`flakelab --help` lists every distro command available on this target.
`flakelab doctor` diagnoses a provisioned distro and says what to run, so prefer it over guessing at broken state.
`flakelab backup` archives the host-specific seed (secrets, keys, tool config) beside the overlay, and `--restore` puts it back.

## Agent sessions and logins

`flakelab sessions` lists the running Claude Code and Codex sessions; `--start <tool> <dir>` hosts one in a window of the `agents` tmux session so it outlives the terminal, `--attach` joins it, `--recent` lists stopped ones with their resume lines.
`tycswap` keeps more than one login per agent CLI: `tycswap add` stores the live one, `tycswap add --login` logs another account in beside it without a logout, `tycswap switch <n|email|alias>` makes a stored one live (a running Claude Code session follows on its next message; Codex keeps its token, so `tycswap codex switch` refuses while one runs unless `--force`), `tycswap list` shows every login's windows, `tycswap run <n>` runs a second account in its own profile beside the live one.
Never `/logout` a tool to change accounts on this box: that discards a refresh token tycswap's store may hold the only current copy of; switch instead, `tycswap add --login` for a new account, and `tycswap add` after a login made by hand.
`flakelab notify` is what the Claude Code and Codex hooks call to push when a session waits on you; `flakelab web` is the dashboard behind a token.
