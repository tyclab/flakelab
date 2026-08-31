# The flakelab option facade: every per-user value an overlay may set, declared
# once with a type and a description.
#
# Before this module the same values travelled as an untyped `userData`
# attrset, which every consumer read field by field with an `or <fallback>`.
# That shape had two defects this file exists to remove:
#   - a typo (`instalKiro`) was not an error, it silently kept the fallback;
#   - the schema was whatever the read sites happened to do, so the only way to
#     learn a field existed was to grep for it.
# The descriptions below ARE the adopter documentation — `mkSystem`'s legacy
# attrset call form and the private overlay template both name these keys, and
# `nix eval .#nixosConfigurations.default.options.flakelab.<name>.description`
# prints what they mean (`nixos-option` needs <nixos-config> in NIX_PATH and so
# does not work on a flake system).
#
# Defaults are exactly the fallbacks the read sites used before, so declaring
# them changes no behaviour. Options WITHOUT a default are the ones that were
# read bare: leaving them unset must keep aborting evaluation rather than
# silently defaulting.
#
# Not declared here: `profiles` / `teams` / `teamCliTools`. Those are consumed
# by profiles/merge.nix BEFORE the module system runs (mkSystem resolves them
# into gitlabGroups / profileCliTools / customAliases / sessionVariables), so
# they never reach an option. flake.nix's strictness guard knows about them.
{ lib, ... }:
let
  inherit (lib) mkOption types;

  # `types.listOf` and `types.nullOr` both carry an `emptyValue` ([ ] and null),
  # which the module system falls back to when an option has no default AND no
  # definition. For a REQUIRED option that is exactly wrong: `cloneExclude` and
  # `gitEditor` were read bare before this file existed, so an overlay omitting
  # one aborted evaluation — with the empty value in place it would instead
  # resolve to [ ] / null and quietly build a different system. Dropping the
  # emptyValue restores the "option used but not defined" abort. Verified: both
  # keys abort when unset, exactly as they did before.
  #
  # Known limit: the strip does NOT survive REDECLARATION. Declaring
  # `flakelab.cloneExclude` or `flakelab.gitEditor` a second time anywhere in the
  # module set makes the module system merge the two types through the type's
  # own `typeMerge`, which rebuilds a stock `listOf` / `nullOr` from the functor
  # payload — emptyValue and all — and the abort silently downgrades to [ ] /
  # null. Nothing in this repo redeclares them; an overlay module that does gets
  # no warning, so don't.
  required = type: type // { emptyValue = { }; };
in
{
  options.flakelab = {
    # ── Set by mkSystem, never by a module ────────────────────────────────────

    # readOnly because the answer is already spent: mkSystem selected the
    # platform module set from this value in the flake's `let` (flake.nix
    # targetModules), before a module system existed to hold a definition. A
    # module redefining it would describe a system nobody built.
    target = mkOption {
      type = types.enum [
        "wsl"
        "proxmox-vm"
      ];
      readOnly = true;
      description = "Platform this system is built for: `wsl` is a NixOS-WSL distro, `proxmox-vm` a Proxmox guest. Pass it to mkSystem (`mkSystem { target = \"proxmox-vm\"; userData = { … }; }`) — it picks the modules in nix/targets/, so it is the one field that cannot travel inside userData.";
    };

    # ── Required: no default, so an overlay that omits one aborts eval ────────
    # These were read bare (no `or`) before, and an overlay missing one has no
    # sensible neutral value: a wrong username or repoPath builds a system for
    # somebody else.

    username = mkOption {
      type = types.str;
      description = "Linux user this system is built for (no dashes); also the home-manager user and the owner of ~/git.";
    };

    repoPath = mkOption {
      type = types.str;
      description = "Absolute path to the flake this distro rebuilds from — the overlay's own directory when there is one. Exported as FLAKELAB_REPO_ROOT by the `flakelab update` / provisioning wrappers and marked `safe.directory` for git.";
    };

    locale = mkOption {
      type = types.str;
      description = "System default locale (i18n.defaultLocale); en_US.UTF-8 is always supported alongside it.";
    };

    gitName = mkOption {
      type = types.str;
      description = "git user.name.";
    };

    gitEmail = mkOption {
      type = types.str;
      description = "git user.email.";
    };

    backupAutostart = mkOption {
      type = types.bool;
      description = "Run `flakelab backup` daily from a systemd user timer (two minutes after the user manager starts, then every 24h). No default on purpose: an overlay that omits it must abort rather than silently ship a distro with no backups.";
    };

    cloneExclude = mkOption {
      type = required (types.listOf types.str);
      description = "Repo names skipped during GitLab group discovery. Explicit `repos` entries bypass it, since naming a repo there is already explicit.";
    };

    gitEditor = mkOption {
      type = required (types.nullOr types.str);
      description = "git core.editor override; null leaves git's own default in place. Read bare, so it must be set — to null if you want no override.";
    };

    # ── Guaranteed present after profiles/merge.nix ───────────────────────────
    # mkSystem folds the selected profiles into these four before the module
    # system sees them, so a definition always arrives. The defaults match the
    # merge's own empty output, which is what an unprofiled overlay produces.

    gitlabGroups = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "GitLab groups cloned in full by `flakelab clone`. Profile groups (profiles/) are unioned in by mkSystem, so do not repeat them.";
    };

    profileCliTools = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Profile-gated CLI tools to install, on top of the profile-derived set. Unmapped names warn rather than fail — see profileCliMap in nix/home/packages.nix.";
    };

    customAliases = mkOption {
      type = types.attrsOf types.str;
      default = { };
      description = "Personal zsh aliases. Applied LAST, so they can override any alias this flake defines.";
    };

    sessionVariables = mkOption {
      type = types.attrsOf types.str;
      default = { };
      description = "NON-SECRET session environment. Each entry also GATES its MCP server (nix/home/mcp.nix) — a missing endpoint means a missing server. Token halves belong in ~/.config/tyc/secrets.env, never here: this lands in the world-readable Nix store.";
    };

    # ── Optional: the defaults are the fallbacks the read sites used ──────────

    # strMatching, not str: an invalid hostname is rejected AS
    # `flakelab.hostName` with the overlay's value in the message, instead of
    # surfacing much later as a type error against networking.hostName in
    # nix/configuration.nix, which names a file the overlay author does not own.
    # The shape is the RFC 1123 label: alphanumeric ends, 63 characters at most.
    hostName = mkOption {
      type = types.strMatching "^[[:alnum:]]([[:alnum:]_-]{0,61}[[:alnum:]])?$";
      default = "flakelab";
      description = "System hostname (networking.hostName), as a single RFC 1123 label (alphanumeric ends, 63 characters at most). The default matches the distro name a fresh provision registers; a box registered under another name, or a second box built from the same overlay, sets its own here. Changing it on an existing box renames it at the next restart, and anything keyed on the hostname (the gate ledger among them) sees a new machine.";
    };

    windowsUsername = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "The C:\\Users\\<name> folder this WSL distro's host belongs to; the zsh init resolves the Windows home from it and jumps to the Linux home when a shell starts there. Null drops that hook, which is what every target other than `wsl` wants — there is no Windows side to jump away from.";
    };

    flakeAttr = mkOption {
      type = types.str;
      default = "default";
      description = "The `nixosConfigurations` attribute `flakelab update` rebuilds (`nixos-rebuild switch --flake path:<repoPath>#<flakeAttr>`). The default names this repo's own output; an overlay flake that describes several boxes gives each one the attribute name it is declared under.";
    };

    sshKeys = mkOption {
      type = types.nonEmptyListOf types.str;
      default = [ "id_ed25519" ];
      description = "Private keys under ~/.ssh that the TTY-gated zsh hook loads into the agent. The FIRST entry is the git/clone identity the kiro and claude activations pass with `ssh -i`.";
    };

    repos = mkOption {
      type = types.listOf types.attrs;
      default = [ ];
      description = "Extra repos beyond group discovery, as `{ relPath; url; }`; relPath is relative to ~/git. These bypass cloneExclude.";
    };

    kiroPluginRepo = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Kiro plugin repo (agents/steering/hooks/skills via `make install-global`); null skips it. The checkout path is derived from the remote so it lands under the GitLab group structure `flakelab clone` already uses.";
    };

    installKiro = mkOption {
      type = types.bool;
      default = true;
      description = "Install the Kiro CLI via its official installer into ~/.local/bin.";
    };

    claudeTrustAll = mkOption {
      type = types.bool;
      default = false;
      description = "Opt in to the `cc` alias (`claude --dangerously-skip-permissions`), which auto-approves every tool with no permission prompts. The Claude-side twin of kiroTrustAll, and off for the same reason: the permission prompt is the only thing standing between an agent and an unreviewed command, so an adopter should not inherit its removal. `c` (plain `claude`) is unaffected.";
    };

    kiroTrustAll = mkOption {
      type = types.bool;
      default = false;
      description = "Opt in to the operator's full-trust Kiro surface: the `kk` alias (`kiro-cli chat --trust-all-tools`) and `chat.disableTrustAllConfirmation` in cli.json. Trust-all auto-approves every tool and OUTRANKS the agent's deniedCommands, so the destructive floor (force-push, reset --hard, clean -f, branch -D, rm -rf) does not apply under it — only the write.deniedPaths secret gates remain. Off by default so an adopter cannot inherit that surface without asking for it; `k` (plain `kiro-cli chat`) is unaffected either way.";
    };

    installClaude = mkOption {
      type = types.bool;
      default = true;
      description = "Install Claude Code via its official installer into ~/.local/bin.";
    };

    # The tiering is the whole point, and it is easy to get backwards:
    #   hard_deny  cannot be cleared by anything, including a direct operator
    #              instruction. Reserve it for boundaries that are never legitimate.
    #   soft_deny  blocks by default but clears when the operator names the specific
    #              operation and its target. This is where destructive-but-legitimate
    #              work belongs.
    # Putting force-push/reset/clean/rm/destroy in hard_deny revokes the operator's
    # own ability to authorise them, which is why they sit in soft_deny here; only
    # credential exfiltration is absolute. "$defaults" inherits the built-in rules at
    # that position — dropping it replaces that whole tier, which silently discards
    # the built-in data-exfiltration rule.
    claudeAutoMode = mkOption {
      type = types.attrs;
      default = {
        allow = [
          "$defaults"
          "gitcleaner retires local branches already merged to main and prints per-branch SHAs for undo; running it with explicit --only names and --yes is routine."
        ];
        soft_deny = [
          "$defaults"
          "Bash(git push --force:*)"
          "Bash(git push -f:*)"
          "Bash(git push * --delete*)"
          "Bash(git branch -D:*)"
          "Bash(git reset --hard:*)"
          "Bash(git clean -f:*)"
          "Bash(git stash drop:*)"
          "Bash(git stash clear:*)"
          "Bash(rm -rf:*)"
          "Bash(rm -fr:*)"
          "Bash(terraform destroy:*)"
          "Bash(tofu destroy:*)"
        ];
        hard_deny = [
          "$defaults"
          "Bash(scp *.env*)"
          "Bash(scp *secret*)"
          "Bash(scp *credential*)"
          "Bash(scp *.pem*)"
          "Bash(scp *.key*)"
          "Bash(scp *id_rsa*)"
          "Bash(rsync *.env*)"
          "Bash(rsync *secret*)"
          "Bash(rsync *credential*)"
          "Bash(rsync *.pem*)"
          "Bash(rsync *.key*)"
          "Bash(rsync *id_rsa*)"
        ];
        # environment: only the built-in defaults. Fleet topology (org name,
        # forge groups, internal DNS zones, marketplace source) is exactly what
        # a shareable repo must not bake in — set the whole attrset from your
        # overlay to add it (the option replaces, it does not merge).
        environment = [ "$defaults" ];
      };
      description = "Auto-mode classifier rules written to settings.autoMode, asserted on every activation alongside defaultMode = \"auto\". User scope is the only scope Claude reads these from, so a provisioner is the only place they can live and stay reproducible. The default is neutral: generic git/IaC guard tiers, no fleet topology. Override the whole attrset from the overlay to describe your environment — see the tiering note above first.";
    };

    claudeAutoUpdatesChannel = mkOption {
      type = types.enum [
        "stable"
        "latest"
      ];
      default = "stable";
      description = "Release channel Claude Code's self-updater follows. Claude Code is the one tool this flake deliberately does not pin, so this is the only control over what lands unreviewed on every box.";
    };

    claudeOutputStyle = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "Concise";
      description = "Claude Code output style asserted into settings.outputStyle. Null leaves the key alone, so the style stays whatever /output-style last picked on the box. Name a built-in (\"Concise\", \"Explanatory\", \"Learning\") or a custom style from ~/.claude/output-styles.";
    };

    mcpPlaywright = mkOption {
      type = types.bool;
      default = false;
      description = "Register the Playwright MCP server. Off by default: it is a browser-driving server with no config predicate of its own — every other server here appears only when its endpoint variable is set — so registering it unconditionally hands an adopter browser automation they never asked for. Extension mode also assumes a Windows Chrome at the path in nix/home/mcp.nix, which is meaningless off WSL.";
    };

    claudeMcpServers = mkOption {
      type = types.attrsOf types.attrs;
      default = { };
      description = "Extra Claude user-scope MCP servers, merged into ~/.claude.json on every rebuild. Same shape as that file's own `mcpServers` entries. The servers this flake defines are already declared in nix/home/mcp.nix; this is where per-developer ones go.";
    };

    claudePluginMarketplaces = mkOption {
      type = types.listOf types.attrs;
      default = [ ];
      description = "Claude Code plugin marketplaces as `{ name; url; }`. `name` must match the marketplace's own .claude-plugin/marketplace.json — a wrong name fails every install silently.";
    };

    claudePluginMarketplace = mkOption {
      type = types.nullOr types.attrs;
      default = null;
      description = "Legacy singular form of claudePluginMarketplaces, still honoured so an overlay predating the list keeps working. Used only when the plural list is empty.";
    };

    claudePlugins = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Claude Code plugins to install. Bare names (\"agents\") resolve against the first marketplace; \"plugin@marketplace\" also works. An mcp-* plugin dropped from this list is uninstalled again.";
    };

    # Opt-in bundle, not a default: it hands every session auto mode without the
    # consent prompt, brings the Remote Control bridge up at startup, and removes
    # the four opt-out env vars a user may have set for themselves. An adopter who
    # never asked for that must not get it from a rebuild.
    claudeAgentDefaults = mkOption {
      type = types.bool;
      default = false;
      description = "Enable the operator's agent-box bundle for Claude Code: settings.permissions.defaultMode = \"auto\", skipAutoPermissionPrompt, remoteControlAtStartup, and removal of the four env vars (DISABLE_TELEMETRY, DO_NOT_TRACK, CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC, DISABLE_GROWTHBOOK) that would otherwise defeat the feature-flag evaluation Remote Control depends on. Off by default: it is a policy an adopter must choose, not a side effect of installing Claude Code. Everything else claude.nix asserts (attribution, feedbackSurveyRate, installMethod, autoUpdatesChannel, autoMode, the force-push deny floor) is written regardless.";
    };

    claudeMdExtra = mkOption {
      type = types.lines;
      default = "";
      description = "Extra markdown appended INSIDE the managed block of ~/.claude/CLAUDE.md, after the neutral text this repo ships (files/config/claude/CLAUDE.md). Where personal workflow rules go — which forge CLI to use for which remote, agent and skill preferences, post-merge housekeeping. The shipped half stays limited to facts about the distro itself, so an adopter is not handed someone else's workflow.";
    };

    whatsappMcpDir = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Absolute path to the whatsapp-mcp-server checkout; null skips the WhatsApp server for both agents. Depends on your gitlabGroups, since clones follow the GitLab namespace.";
    };

    bitwardenServer = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Endpoint the Bitwarden CLI is pointed at (`bw config server`), rewritten on every activation when it differs. null leaves the CLI on whatever endpoint it already has — its own default is US, so set this (e.g. \"https://vault.bitwarden.eu\") when your vault lives in another region and `bw login` fails against US.";
    };

    extraReposDirs = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Extra roots the gitcheck/gitclean aliases scan beyond ~/git — e.g. a Windows-mount tree still holding clones that exist nowhere else.";
    };

    backupRoot = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Absolute path of the flakelab backup payload root (secrets, keys, per-host config); null resolves to `\${repoPath}/files/config`, the Windows-mount default `flakelab backup` has always used. A target with no such mount (nothing survives a proxmox-vm guest's own disk across re-provisioning) points this at a mount that outlives it instead.";
    };

    stateRoot = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Absolute path of a directory for the SHAREABLE backup state — the merged zsh history, Claude auto-memory and (with stateTranscripts) Claude transcripts — so it can be replicated between machines by whatever folder-sync client you already run (Syncthing, Dropbox, rclone, a NAS client, nothing at all). null keeps everything in the payload under repoPath as before. Must be a plain directory, never a git checkout (sync clients write conflict copies of .git internals) and never inside repoPath. Credentials and host-specific config never go there. Exported as FLAKELAB_STATE_ROOT to `flakelab backup`.";
    };

    stateTranscripts = mkOption {
      type = types.bool;
      default = false;
      description = "Also keep Claude Code session transcripts (~/.claude/projects/<slug>/*.jsonl) in stateRoot, grow-only in both directions. Off by default and separate from memory on purpose: a transcript is the verbatim text of every session — large, growing, and including anything ever pasted — so opting in means that folder, and whatever replicates it, holds that. Ignored when stateRoot is null.";
    };

    stateSyncInterval = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "systemd time span (OnUnitActiveSec syntax, e.g. \"30min\") between runs of `flakelab backup --state-only` — the narrow sync that moves ONLY the state-root categories (merged history, Claude memory, transcripts) in both directions, takes no snapshot and never touches the payload. null schedules none, leaving the state root to the daily full backup's push and manual `--restore` pulls. Needs stateRoot and backupAutostart: without a root there is nothing to sync, and a box that opted out of scheduled backups opted out of this too. The full payload pass stays on its own 24h timer either way.";
    };
  };
}
