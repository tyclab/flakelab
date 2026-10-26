# AGENTS.md — flakelab

Shareable NixOS environment for WSL and Proxmox guests. `lib.mkSystem` is the
overlay interface; personal values belong in a private overlay, while
`nix/users/default.nix` keeps neutral placeholders.

- Keep this public repository free of private addresses, personal/employer details,
  credentials and host-specific configuration. Use the repo-local commit identity
  or a GitHub noreply address.
- Secrets are read at use time from `/run/secrets/flakelab-env` or
  `~/.config/flakelab/secrets.env`, never plaintext in the flake. A locked Bitwarden
  vault waits for the operator's `bwu`; never request or inline its session token.
- Tools and environment changes come from the flake. `flakelab --help` lists the
  supported commands; use `flakelab doctor` to diagnose a provisioned box.
- Preserve per-command pinned PATHs and exported environment. User commands go
  through the `flakelab` router; gitchecker, gitcleaner and gitpublisher remain
  standalone. Test harnesses retain their existing names.
- Never use `/logout` to change agent accounts: use tycswap. Never run
  `wsl --shutdown`, `wsl --terminate`, or reboot a box from an agent session.
  Distro lifecycle tests require an expendable host-side session.
- Keep one repository instruction entry point here. Task guidance lives in
  `docs/agents/`; human setup/architecture stays in the root docs. Follow
  [maintenance](docs/agents/maintenance.md), preserving real rules when trimming.
- Preserve repository merge defaults and hooks. This is GitHub: publish with
  `git push` and `gh`, specifying `--repo tyclab/flakelab`. gitpublisher is
  GitLab-only. Never force-rewrite a shared branch.
- Validate the affected offline suite after script changes; `make test` runs all
  offline suites. `nix flake check` is the full gate. Run `make lint` and `nix fmt`
  before publishing; CI also scans for secrets. Keep tests registered in both
  Makefile and `flake.nix`; outputs/checks support x86_64-linux.

## Read before the task

- CLI, sessions, OAuth/MCP, web, notifications or publishing tools:
  [CLI contracts](docs/agents/cli-development.md).
- Overlay generation, switching or provisioning:
  [provisioning](docs/agents/provisioning.md) and `known-issues.md`.
- Agent instructions, memory paths or dialog behavior:
  [client notes](docs/agents/agent-clients.md).
- Hooks, suites or CI: [validation](docs/agents/validation.md).

Keep `claudeAutoMemoryDirectory` behavior separate from transcript paths: changing
the memory store does not migrate directory-keyed transcripts. Do not duplicate
operator manuals in the managed instruction templates.
