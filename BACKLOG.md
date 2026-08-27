# Backlog

Open work that is not a bug in a released behaviour. Environment problems and
their workarounds live in [known-issues.md](known-issues.md); this file is for
things we intend to change.

Tracked here rather than in the GitHub issue tracker: the work is decided in
the repository, alongside the code it describes.

## Agent-surface hardening

`security` · mostly closed

Every adopter used to inherit the operator's full-trust agent setup without
opting in. Five of six items are now gated behind options that default off:

| surface                                                                                  | option                         |
| ---------------------------------------------------------------------------------------- | ------------------------------ |
| `kk` = `kiro-cli chat --trust-all-tools`                                                 | `flakelab.kiroTrustAll`        |
| `cli.json` `chat.disableTrustAllConfirmation`                                            | `flakelab.kiroTrustAll`        |
| `cc` = `claude --dangerously-skip-permissions`                                           | `flakelab.claudeTrustAll`      |
| `permissions.defaultMode = "auto"`, `skipAutoPermissionPrompt`, `remoteControlAtStartup` | `flakelab.claudeAgentDefaults` |
| the Playwright MCP server                                                                | `flakelab.mcpPlaywright`       |

`claudeDisableAttribution` is gated on `installClaude` like every sibling
activation, and `@jarahkon/hass-mcp-server` is version-pinned like the other
MCP servers.

**Still open:** the marketplace `recommended-permissions.json` merge
(`nix/home/claude.nix`) is neither validated nor pinned. The activation
searches the marketplace clone for a file of that name and merges whatever it
finds into Claude's pre-approved permission set. A malformed or hostile file
there widens the allowlist with no check. Validate the shape before merging,
and decide whether the source should be pinned rather than discovered.

## Retire the wslkube migration path

`tech-debt`

Two halves of the same cleanup.

**The code path.** `setup-wsl-nix.ps1 migrate`, the wslkube-reading half of
`provision`, `nix-backup --from/--instance`, and the migration/parity/drift
prose all exist to move off wslkube. Both machines are provisioned on flakelab,
so wslkube is read-only DR for one release cycle and then the code path goes.

**The docs.** wslkube is a private repository that will not be published, but
the public tree explains its own config schema in terms of it —
`files/config/user_data.example.yaml` (11 mentions), plus help text in
`files/scripts/nix-overlay-generate` and `files/scripts/nix-backup`. A reader
hits references they cannot resolve. The example config should describe the
schema on its own terms regardless of when the code path is retired.

## `gitpublisher` refuses non-GitLab remotes, but AGENTS.md points agents at it

`tech-debt`

This repository lives on GitHub, but `gitpublisher` opens GitLab merge requests
and refuses any remote that is not GitLab (exit 2). `AGENTS.md` presents it as
the way to publish work, so a coding agent on a fork hits that refusal with no
alternative offered. `CONTRIBUTING.md` correctly says "pull request" and does
not send humans there, so this only affects agents.

Options: teach `gitpublisher` a GitHub backend via `gh`, or scope the
`AGENTS.md` guidance so it names plain `git push` + `gh pr create` for this
repo and keeps `gitpublisher` for GitLab clones.

## Soften the first-run output for someone with no GitLab and no tokens

`enhancement`

On a machine with no `GITLAB_TOKEN`, `setup-wsl-nix.ps1` prints things that
only make sense to the original author:

- "overlay is missing SSH key ... built but unconfigured"
- a wslkube "`migrate` seeds both" hint, naming an unpublished repository
- it runs `flakelab clone`, which fails with "GITLAB_TOKEN not set — source
  ~/.config/tyc/secrets.env (from OpenBao)"
- the doctor says "populate it from OpenBao" and reports "nix-doctor: N
  problem(s)" under a command now named `flakelab doctor`

Skip the clone when there is no token, drop OpenBao and wslkube wording from
anything a first-time user sees, and have the doctor banner match its own
command name.

## Clone hygiene for consumers

A clone made with a partial-clone filter (`--filter=blob:none`) cannot be
evaluated in place: `nix flake check` and `nix fmt` fail with
`unsupported extension name extensions.partialclone`, because nix's libgit2
rejects the extension. `nix flake check path:.` works around it; converting the
clone with `git fetch --refetch --no-filter <remote>` and dropping the promisor
config fixes it properly. Worth a line in CONTRIBUTING.md.
