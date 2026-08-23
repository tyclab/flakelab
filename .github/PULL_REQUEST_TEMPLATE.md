## What this changes

<!-- One or two sentences. Link the issue if there is one: Fixes #123 -->

## Why

<!-- The problem this solves. Skip if it is obvious from the above. -->

## Checklist

- [ ] `make lint` passes (the pre-commit suite — CI runs the same target).
- [ ] `nix flake check` passes, or I have said below why it cannot run here.
- [ ] I ran the offline suite for anything I touched under `files/scripts/`
      (`make test` runs all five).
- [ ] `CHANGELOG.md` has an entry under `## [Unreleased]` if this is
      user-visible.
- [ ] No secrets, tokens, private hostnames or personal paths in the diff.

## Anything a reviewer should know

<!-- Sharp edges, things you decided against, follow-up work. -->
