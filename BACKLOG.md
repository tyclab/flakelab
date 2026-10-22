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

## Retire the wslkube migration path

`tech-debt`

Two halves of the same cleanup.

**The code path.** `setup-wsl-nix.ps1 migrate`, the wslkube-reading half of
`provision`, `flakelab backup --from/--instance`, and the migration/parity/drift
prose all exist to move off wslkube. Both machines are provisioned on flakelab,
so wslkube is read-only DR for one release cycle and then the code path goes.

**The docs.** wslkube is a private repository that will not be published, but
the public tree explains its own config schema in terms of it —
`files/config/user_data.example.yaml`, plus help text in
`files/scripts/nix-overlay-generate` and `files/scripts/nix-backup`. A reader
hits references they cannot resolve. The example config should describe the
schema on its own terms regardless of when the code path is retired.

## Soften the first-run output for someone with no GitLab and no tokens

`enhancement`

On a machine with no `GITLAB_TOKEN`, `setup-wsl-nix.ps1` prints things that
only make sense to the original author:

- "overlay is missing SSH key ... built but unconfigured"
- a wslkube "`migrate` seeds both" hint, naming an unpublished repository
- it runs `flakelab clone`, which fails with "GITLAB_TOKEN not set — source
  ~/.config/flakelab/secrets.env"

Skip the clone when there is no token, and drop the wslkube wording from
anything a first-time user sees.

## Verify remote sessions on a real box

`enhancement`

The verifications [remote-sessions.md](remote-sessions.md) lists: a tmux-hosted
session under Remote Control, the host route from a phone, mosh through a
network change, the ntfy payload.
