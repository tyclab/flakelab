# Validation and CI

Read for this topic; paths below are relative to the repository root unless stated otherwise.

- Changing any of these means running its offline suite. `make test` runs every
  offline `test-*` under `files/scripts/` except `test-provision-nix` (the
  Makefile's `test` target is the list of record); run it while iterating, and
  `nix flake check` is the full gate. A new suite goes into that list and into
  `nix/checks.nix` as a `checks.<system>.<name>` entry by hand: nothing discovers it.
  These are TEST HARNESSES, not user commands, so the `flakelab` CLI did not
  rename them: `test-nix-backup`, `test-nix-doctor`, `test-nix-overlay-generate`,
  `test-nix-update` and `test-nix-provision` keep the old prefix on purpose,
  because renaming them would drag `Makefile` and `nix/checks.nix`'s
  `checks.<system>.*` along for no change in behaviour. They run
  the scripts by path, not by command name. CI runs the same suites as flake
  checks — `nix flake check` (the `test` job) builds one `checks.<system>.<suite>`
  per suite, plus `statix` and `deadnix` — so a red suite blocks the pull
  request rather than surviving to main. Those checks copy the WHOLE tree
  into the sandbox, not just `files/scripts/` — `test-nix-overlay-generate`
  asserts against the tracked `templates/overlay/` and
  `files/config/user_data.example.yaml`.
- CI's other jobs are `lint` (`make lint && nix fmt && git diff --exit-code`)
  and `gitleaks`. Neither `make lint` nor `nix flake check` formats, so run
  `make lint-nix` (or `nix fmt`) before pushing a `.nix` change. Run
  `make install-hooks` once per clone, inside `nix develop`. Flake outputs and
  checks exist for `x86_64-linux` only.
