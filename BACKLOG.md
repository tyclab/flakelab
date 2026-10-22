# Backlog

Open work that is not a bug in a released behaviour. Environment problems and
their workarounds live in [known-issues.md](known-issues.md); this file is for
things we intend to change.

Tracked here rather than in the GitHub issue tracker: the work is decided in
the repository, alongside the code it describes.

## Validate the marketplace permission files

`security`

`files/scripts/nix-update` searches the marketplace clone for
`recommended-permissions.json` and `recommended-ask.json` and writes whatever it
finds as Claude's `permissions.allow` and `permissions.ask`. A malformed or
hostile file there widens the allowlist with no check. Validate the shape before
writing, and decide whether the source should be pinned rather than discovered.

## Soften the first-run output for someone with no GitLab and no tokens

`enhancement`

On a machine with no `GITLAB_TOKEN`, `setup-wsl-nix.ps1` prints things that
only make sense to the original author:

- "overlay is missing SSH key ... built but unconfigured"
- it runs `flakelab clone`, which fails with "GITLAB_TOKEN not set — source
  ~/.config/flakelab/secrets.env"

Skip the clone when there is no token.

## Verify remote sessions on a real box

`enhancement`

The verifications [remote-sessions.md](remote-sessions.md) lists: a tmux-hosted
session under Remote Control, the host route from a phone, mosh through a
network change, the ntfy payload.
