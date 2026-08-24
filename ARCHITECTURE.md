# Architecture

How flakelab is put together, and why. Usage lives in
[`README.md`](README.md); hazards in [`known-issues.md`](known-issues.md).

## Principles

1. **Two layers.** System-scoped configuration in `nix/configuration.nix`,
   user-scoped in `nix/home/` (Home Manager as a NixOS module), split by
   concern: `packages`, `zsh`, `git-ssh`, `mcp`, `kiro`, `claude`, `tooling`,
   `health`, `backup`.
2. **Declarative first.** The only imperative exceptions are foreign binaries
   with no nixpkgs path (kiro-cli, the Claude installer) and SSH key material —
   both behind guarded, idempotent activation, never in the store.
3. **Per-user values are data.** `nix/users/default.nix` holds placeholders; real
   values are injected by the private overlay through `lib.mkSystem`. Flakes
   evaluate only git-tracked files, which is what keeps a public fork free of
   personal data.
4. **Secrets never enter repo or store.** They arrive at runtime from a vault as
   `~/.config/tyc/secrets.env`, sourced at shell start.
5. **Reuse the repo-discovery logic** rather than rewriting it: `clone-repos` and
   `activate-hooks` descend from an Ansible/PowerShell predecessor, wrapped with
   a pinned PATH (`nix/scripts.nix`). They have since diverged materially — the
   predecessor is the design ancestor, not a copy source.

## Options and the overlay

`nix/options.nix` declares every per-user value once, with a type, a default and
a description. Before it, the same values travelled as an untyped `userData`
attrset that each consumer read with an `or <fallback>`: a typo silently kept
the fallback, and the only way to learn a field existed was to grep. Now a typo
or a wrong type aborts evaluation. Options **without** a default (`username`,
`repoPath` among them) must keep aborting when unset rather than defaulting.

`lib.mkSystem` has two call forms. The attrset form takes the declared keys
directly; the second form, `{ userData, modules, homeModules }`, lets an overlay
add arbitrary NixOS or Home Manager modules, so an overlay never has to fork
this repo. A `modules` entry may also set any `flakelab.*` option and outranks
the attrset (which is applied with `mkDefault`): scalars and lists are replaced,
while `sessionVariables`, `customAliases` and `claudeMcpServers` merge per key —
replacing one of those wholesale needs `lib.mkForce`.

Anything that describes the **operator** rather than the distro is an option
that defaults to off, because every activation here runs on every adopter's box:

- `claudeAgentDefaults` (bool, default `false`) — the agent-box bundle written
  into `~/.claude/settings.json`: `permissions.defaultMode = "auto"` with the
  consent flag that must accompany it, `remoteControlAtStartup`, and the removal
  of the four env vars (`DISABLE_TELEMETRY`, `DO_NOT_TRACK`,
  `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`, `DISABLE_GROWTHBOOK`) that would
  defeat it. Off, those keys and those vars are left exactly as the user has
  them. Everything else `claudeDisableAttribution` asserts — attribution, the
  classifier rules, `installMethod`, `autoUpdatesChannel`, the force-push deny
  floor — is unconditional, and the whole activation is gated on `installClaude`.
- `claudeMdExtra` (lines, default `""`) — appended inside the managed block of
  `~/.claude/CLAUDE.md`, after the text `files/config/claude/CLAUDE.md` ships.
  That shipped half stays limited to facts about the distro; personal workflow
  rules (which forge CLI for which remote, agent preferences, post-merge
  housekeeping) go here, from the private overlay.
- `bitwardenServer` (nullable string, default `null`) — `null` skips the
  `bw config server` activation entirely rather than rewriting someone's region
  on every rebuild.

`profiles/` is resolved **before** the module system runs: `profiles/merge.nix`
turns the selected `profiles` into effective `gitlabGroups`, `profileCliTools`,
`customAliases` and `sessionVariables`, which is why `profiles` itself is not an
option. Selecting none is legal but warns — no profile packages, no profile
groups.

Generating the overlay from a `user_data.yaml` is one script with two call
sites, because it reads `templates/overlay/` and `profiles/` relative to itself:

- `./files/scripts/nix-overlay-generate` from a **checkout** reads that checkout
  and defaults `--flakelab-ref` to `path:` it. This is the bootstrap path, and
  the one to use while editing the templates.
- `flakelab overlay-gen` from **PATH** reads the installed flake generation out
  of a store path holding exactly the script, `templates/overlay/` and
  `profiles/`. There `--flakelab-ref` is **required**: the only value it could
  default to is a frozen, garbage-collectable store path, and writing that into
  an overlay would pin it to something the next GC removes.

Both rewrite one anchored line in `templates/overlay/flake.nix` (keyed on a
`# flakelab-url:` marker comment, not on the URL) and abort if that marker is
not present exactly once. Git-ignore the overlay's own `flake.lock`: a committed
lock pins the NAR hash of a local checkout, and the next edit over there aborts
the build with "NAR hash mismatch".

## The CLI

`flakelab` is one binary with subcommands, and it is a **router**
(`files/scripts/flakelab`): each subcommand execs the same per-command wrapper
`nix/scripts.nix` builds, so every one keeps its own pinned PATH and exported
environment (`FLAKELAB_REPO_ROOT` from `repoPath`, `FLAKELAB_BACKUP_ROOT`,
`FLAKELAB_STATE_ROOT` from `stateRoot` when set). `nix/cli.nix` assembles those
wrappers into the dispatch directory the router reads.

`FLAKELAB_REPO_ROOT` is what makes `flakelab build-distro` and
`flakelab test-provision` callable from anywhere: both need the repo root, and
deriving it from `$0` yields a `/nix` store path once they are packaged. The
`files/scripts/<name>` copies still work in a plain checkout, and the router
dispatches to those copies when it is run from one.

`gitchecker`, `gitcleaner` and `gitpublisher` stay standalone commands — no
namespace collision, and other repos invoke them by name. Each subcommand keeps
its own `--help`, flags, exit codes and `--json` output.

## Why two switches

A `provision` applies the overlay twice. The SSH-dependent activation steps —
plugin clones, the marketplaces, the statusline that follows them — need a
passphrase-unlocked ssh-agent, and the key can only be copied into `~` once the
Linux user exists, which is what the first switch creates. So the order is
switch #1 -> seed key and `secrets.env` -> load the agent (`-SshPassphrase` for
an unattended run) -> switch #2, which completes what #1 could only defer.

Switch #2 is **conditional on that agent load succeeding**: with no private key
in the overlay's `files\config\shared\ssh\keys\` there is nothing to load, and
the script skips the second switch rather than running one that could only defer
again. So the keyless run the README recommends applies the overlay once, and
the SSH-dependent steps stay deferred until a `flakelab update` from inside the
distro with an agent holding a key. `-SkipSecondSwitch` opts out explicitly when
those steps are already done; either way a one-switch run ends with no plugins
and no statusline, and `flakelab doctor` is the only hint.

Both switches wipe VM-wide WSL interop, so each is followed by an interop probe
and an offer to `wsl --shutdown` (`-Shutdown` answers yes up front; declining
right after switch #1 stops the run before anything is seeded and prints how to
resume). A non-interactive run never shuts anything down by itself.

## Activation and the health check

Activation ends in a health check that fails the rebuild on anything a step
reported as a defect, while work it structurally cannot do — no seeded SSH key,
no unlocked ssh-agent, no network — is recorded as **deferred** and never fatal.
That is what lets the first rebuild of a fresh distro succeed before anything
has been seeded into `~`. `flakelab doctor` covers the rest, because it runs
from an interactive shell: an agent holding a key, `glab` auth, a working
`git@gitlab.com`.

Claude Code state is owned by idempotent jq/marker merges rather than store
symlinks, because Claude rewrites these files itself:

- **`settings.json`** — attribution, the classifier rules (`claudeAutoMode`),
  `installMethod = native`, `autoUpdatesChannel` (`claudeAutoUpdatesChannel`),
  the output style when `claudeOutputStyle` names one,
  the bridge environment, the statusline, and a `permissions.deny` **floor**
  against force-pushing. The floor is unioned in, so rules added by hand
  survive; nothing else in the file is asserted whole except `autoMode`. The
  permission mode is not among them unless `claudeAgentDefaults` says so.
- **`~/.claude.json`** — user-scope MCP servers from `claudeMcpServers`,
  installed mode 600, since the same file holds Claude's account and OAuth
  state.
- **`permissions.allow`** — merged from the marketplace clone's
  `recommended-permissions.json`, located by searching the clone rather than by
  a fixed path (it has moved once already, and a wrong path defers forever
  instead of failing). A missing clone defers; a clone without the file warns,
  because no retry fixes that.
- **`CLAUDE.md`** — a `<!-- BEGIN managed by flakelab -->` block holding the
  shipped facts plus `claudeMdExtra`; anything outside the markers is left alone.

`~/.gitconfig` is a flake-owned `[include]` of `~/.config/git/config`. git reads
the legacy path last, so a real file there overrides every key `programs.git`
sets and `backupFileExtension` cannot catch it — Home Manager writes the XDG
path while a restore writes the legacy one. `flakelab doctor` reports which file
`user.email` actually resolves to. The trade: `git config --global` now writes
to the read-only store and fails; git config is declarative here.

## Backup, and what a payload is

`flakelab backup` writes two different kinds of thing, which want opposite
treatment:

- The **provisioning seed** — `secrets.env`, the SSH key, glab/kube/helm config,
  the Claude settings with their environment block — describes _this_ host and
  must never leave the overlay checkout.
- The **state** — merged shell history, Claude Code auto-memory per checkout,
  optionally session transcripts — is what you want on every machine you work
  from.

`stateRoot` splits them: set it and the state is written there instead of into
the payload. Whether that directory is replicated by Syncthing, Dropbox, rclone,
a NAS client or nothing at all is outside this repo's knowledge.

```text
<stateRoot>/shell/.zsh_history_merged                 # union of every machine's history
<stateRoot>/claude/projects/<slug>/memory/            # auto-memory, per checkout path
<stateRoot>/claude/projects/<slug>/<session>.jsonl    # transcripts, opt-in
```

Restore on the second machine with `flakelab backup --restore`; a daily timer
keeps both sides converging. Memory is keyed by the checkout's **absolute path**,
so keep checkouts at the same path on both boxes — and never let a checkout live
inside the synced folder.

The restore is additive: it no longer deletes local files the backup does not
have. Rollback snapshots (`snapshots/` beside the payload) cover the payload
only; the state root is not snapshotted, because every write into it is additive
or a union, and the sync client's own version history is the rollback there.

### Shared state and the secret gate

There is no cross-machine lock — the `.backup.lock` beside the payload
serialises runs on one box and is invisible to the other — so every write into
the state root has to converge on its own:

- **History** is a union: additive, deduplicating and stability-checked, and the
  first run with a state root folds the payload's existing merge in.
- **Conflict copies** (`<name>_<host>_<date>_Conflict`,
  `<name>.sync-conflict-<date>`, `<name> (conflicted copy …)` — every client has
  its own spelling) are handled by kind: a conflict copy of one of the three
  files both machines rewrite — the merged history, the shared `MEMORY.md` index
  and the gate's `decisions.jsonl` — is merged in and then removed; every other
  conflict copy, and the metadata litter (`@eaDir`, `.DS_Store`, `Thumbs.db`,
  `desktop.ini`), is ignored on restore and never copied into `$HOME`.
- **Memory** backs up and restores additively; `MEMORY.md` restores as the
  line-union of both sides, topic files are last-writer-wins. Deletions
  therefore do not propagate.
- **Transcripts** are opt-in (`stateTranscripts`) and grow-only in both
  directions: a copy with fewer lines never overwrites one with more, `--force`
  included. Lines, not bytes — a redacted copy can outweigh its source.

**The gate.** The merged history and the transcripts are everything ever typed
at a prompt or printed in a session, including anything pasted before you had a
vault; whatever replicates that folder keeps version history of it. So every
backup scans what it is about to write into the state root with `gitleaks` and
holds findings back:

- A flagged **history** record is held back whole, header and continuation
  lines; the rest of the merge still goes.
- A flagged **transcript** is copied with the secret replaced by
  `[REDACTED:<rule>]`; if redacting would break the JSON the file is held back.
- **Local files are never modified by a backup** — the gate decides what is
  written out, not what you keep.
- **Memory is not gated**: it is small, curated and hand-written. History is
  none of those, which is the point.

Held findings are listed in the run summary; a run with them warns rather than
fails. `flakelab backup --review-secrets` walks them one at a time: **delete**
from every local source (a pre-scrub copy is kept), **keep** it local and never
sync it, or **allow** it. Decisions are stored in the state root as
fingerprints, never secrets, so one triage settles a secret for every machine's
_syncing_ — but a **delete** rewrites local files, and only the box you are
sitting at may do that, so it stays pending elsewhere until that box runs its
own review. `--review-secrets` needs a terminal (exit 1 without one) and refuses
`--dry-run`, because it is the one mode that rewrites local files.

A fingerprint is a plain `sha256`, not an HMAC, and it lives in a folder
something replicates: a low-entropy secret — a short password, a PIN, a token
from a small keyspace — can be recovered from it by guessing offline. Treat the
decisions file as sensitive. If the scanner is missing from PATH the run records
a failure and writes neither category, `--dry-run` included: nothing ungated
reaches the state root.

Two refusals are built in: a `stateRoot` that is, or sits inside, a git checkout
is rejected outright (sync clients write conflict copies of `.git/config`,
`index` and `packed-refs` — a corrupted repository, not a merge; observed, not
theoretical), and a root whose parent directory is missing (the sync drive is
not mounted) skips the state categories with a recorded failure rather than
silently writing them somewhere else. On a Windows drive POSIX modes are lost —
one more reason the seed stays out.

## Language runtimes

`nix/home/packages.nix` ships Go (`gopls`), Node 24 (`nodeenv` for the
npm-globals baseline, `bun`, `typescript`, `typescript-language-server`) and
`python3` with `uv` and `pyright`. The Python interpreter is there for
`#!/usr/bin/env python3` scripts — without it every such script dies with "no
such file or directory", and the Claude marketplace's PreToolUse guard hooks are
exactly that. There is deliberately **no `pip`**: `uv` is the installer for
Python tooling.

## Packaging notes

`programs.git.settings` is canonical
(`extraConfig`/`userName`/`userEmail` are deprecated aliases);
`programs.ssh.enableDefaultConfig` is slated for deprecation, so forced `"*"`
defaults migrate to `programs.ssh.settings."*"`; the NixOS-WSL image is
`config.system.build.tarballBuilder` and native Docker is
`virtualisation.docker.enable`, **not** `wsl.docker-desktop.enable`;
`claude-code` in nixpkgs lags what this environment needs, and kiro-cli has no
nixpkgs path at all, so both come from their official installers through
activation with `programs.nix-ld`.
