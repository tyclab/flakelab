# Wrappers around files/scripts, with a pinned PATH each.
# `cfg` is the flakelab option set, so every field read below is already typed and
# defaulted and nothing here needs an `or` fallback.
{ pkgs, cfg }:
let
  inherit (pkgs) lib;
  # From the flake source, not repoPath: an overlay's repoPath has no files/scripts.
  s = ../files/scripts;
  # For nix-overlay-generate alone, which requires templates/overlay/ and profiles/
  # next to itself: a store path shaped like the repo root, holding only what the
  # script reads. Not `../.`, which materialises a second full copy of the tree.
  # Add to this list when the script learns to read anything else from its checkout,
  # or it dies in installed mode while checkout mode stays green.
  srcRoot = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../files/scripts/nix-overlay-generate
      ../files/scripts/lib/overlay-git.zsh
      ../templates/overlay
      ../profiles
    ];
  };
  # What lib/overlay-git.zsh measures a plain-directory overlay's first commit
  # against. Named, because a store path cannot start with a dot.
  overlayGitignore = builtins.path {
    path = ../templates/overlay/.gitignore;
    name = "flakelab-overlay-gitignore";
  };
  zsh = "${pkgs.zsh}/bin/zsh";
  bin = lib.makeBinPath;
  # Backups must land somewhere that survives distro re-provisioning.
  # Beside repoPath, never under it: every `nix` command given the overlay copies
  # the whole directory into the world-readable store, .gitignore or not, and the
  # payload is keys and cleartext secrets. setup-wsl-nix.ps1 (Get-PayloadRoot) and
  # nix-overlay-generate apply the same `-payload` rule on their side.
  backupRoot =
    if cfg.backupRoot == null then
      "${cfg.repoPath}-payload"
    else
      lib.throwIf (cfg.backupRoot == cfg.repoPath || lib.hasPrefix "${cfg.repoPath}/" cfg.backupRoot)
        "flakelab.backupRoot (${cfg.backupRoot}) is inside repoPath (${cfg.repoPath}): nix copies the overlay directory whole into the world-readable store, so the payload - keys, cleartext secrets - must live outside it. Leave it null for ${cfg.repoPath}-payload."
        cfg.backupRoot;
  # Exported only when set: unset means "everything stays in the payload" to
  # nix-backup and "no held-findings check" to nix-doctor. The kiro-plugin path comes
  # from the same derivation activation clones into, so a doctor cannot diagnose a
  # path nothing writes.
  kiroPlugin = import ./kiro-plugin.nix { inherit lib cfg; };
  kiroPluginPath = kiroPlugin.path;
  kiroPluginDir = kiroPlugin.dir;
in
# `rec` for one self-reference: the nix-update wrappers pin `nix-clone-repos`, which
# the CLI keeps off PATH under its own name, so `--all` would trip its guard.
rec {
  clone-repos = pkgs.writeShellScriptBin "clone-repos" ''
    export PATH=${
      bin [
        pkgs.zsh
        pkgs.git
        pkgs.openssh
        pkgs.coreutils
        pkgs.gnugrep
        pkgs.findutils
      ]
    }:$PATH
    exec ${zsh} ${s}/clone-repos "$@"
  '';

  activate-hooks = pkgs.writeShellScriptBin "activate-hooks" ''
    export PATH=${
      bin [
        pkgs.zsh
        pkgs.git
        pkgs.pre-commit
        pkgs.gnumake
        pkgs.findutils
        pkgs.gnugrep
        pkgs.coreutils
        pkgs.gnused
      ]
    }:$PATH
    exec ${zsh} ${s}/activate-hooks "$@"
  '';

  # Every sweep parses forge JSON; gh is probed only for a github.com remote.
  gitchecker = pkgs.writeShellScriptBin "gitchecker" ''
    export PATH=${
      bin [
        pkgs.zsh
        pkgs.git
        pkgs.jq
        pkgs.glab
        pkgs.gh
        pkgs.coreutils
        pkgs.findutils
        pkgs.gnugrep
      ]
    }:$PATH
    exec ${zsh} ${s}/gitchecker "$@"
  '';

  # The mutating half of the sweep, sharing gitchecker's discovery and forge routing.
  gitcleaner = pkgs.writeShellScriptBin "gitcleaner" ''
    export PATH=${
      bin [
        pkgs.zsh
        pkgs.git
        pkgs.jq
        pkgs.glab
        pkgs.gh
        pkgs.coreutils
        pkgs.findutils
        pkgs.gnugrep
      ]
    }:$PATH
    exec ${zsh} ${s}/gitcleaner "$@"
  '';

  # No gh: GitLab-only, and the script refuses other forges itself.
  gitpublisher = pkgs.writeShellScriptBin "gitpublisher" ''
    export PATH=${
      bin [
        pkgs.zsh
        pkgs.git
        pkgs.jq
        pkgs.glab
        pkgs.coreutils
        pkgs.gnugrep
      ]
    }:$PATH
    exec ${zsh} ${s}/gitpublisher "$@"
  '';

  # Wrapped so it is callable by hand: its output is what a discovery gap is debugged
  # with.
  glab-group-projects = pkgs.writeShellScriptBin "glab-group-projects" ''
    export PATH=${
      bin [
        pkgs.zsh
        pkgs.glab
        pkgs.jq
        pkgs.coreutils
      ]
    }:$PATH
    exec ${zsh} ${s}/glab-group-projects "$@"
  '';

  # --save lands under FLAKELAB_STATE_ROOT, so the list replicates with the
  # transcripts it names. tmux is the session host --start / --attach / --open
  # use; the same package the user's shell has, so a view and the server agree.
  claude-sessions = pkgs.writeShellScriptBin "claude-sessions" ''
    ${lib.optionalString (cfg.stateRoot != null) ''
      export FLAKELAB_STATE_ROOT=${lib.escapeShellArg cfg.stateRoot}
    ''}
    export PATH=${
      bin [
        pkgs.zsh
        pkgs.coreutils
        pkgs.procps
        pkgs.gnugrep
        pkgs.gawk
        pkgs.jq
        pkgs.tmux
      ]
    }:$PATH
    exec ${zsh} ${s}/claude-sessions "$@"
  '';

  # The store is the script's own; flock serialises writers, pgrep counts the
  # tool's running sessions for the post-switch line. Sourced from `s`, so the
  # adapters under lib/ sit beside it in the store. The user's PATH stays
  # behind the pinned set: the Codex adapter runs the installed `codex`
  # (~/.local/bin) for its usage read and profile check.
  accounts = pkgs.writeShellScriptBin "accounts" ''
    export FLAKELAB_ACCOUNTS_TOOLS=${lib.escapeShellArg (lib.concatStringsSep "," cfg.accounts.autoSwitchTools)}
    export FLAKELAB_ACCOUNTS_SESSION_THRESHOLD=${toString cfg.accounts.sessionThreshold}
    export FLAKELAB_ACCOUNTS_WEEK_THRESHOLD=${toString cfg.accounts.weekThreshold}
    export FLAKELAB_ACCOUNTS_MODEL_THRESHOLD=${toString cfg.accounts.modelThreshold}
    export FLAKELAB_ACCOUNTS_MODEL_WINDOWS=${lib.escapeShellArg (lib.concatStringsSep "," cfg.accounts.modelWindows)}
    export FLAKELAB_ACCOUNTS_STRATEGY=${cfg.accounts.strategy}
    export PATH=${
      bin [
        pkgs.zsh
        pkgs.coreutils
        pkgs.util-linux
        pkgs.procps
        pkgs.gnugrep
        pkgs.gawk
        pkgs.curl
        pkgs.sqlite
        pkgs.jq
      ]
    }:$PATH
    exec ${zsh} ${s}/accounts "$@"
  '';

  # The endpoint is read from secrets.env at use time; nothing is baked in.
  notify = pkgs.writeShellScriptBin "notify" ''
    export PATH=${
      bin [
        pkgs.zsh
        pkgs.coreutils
        pkgs.jq
        pkgs.curl
      ]
    }:$PATH
    exec ${zsh} ${s}/notify "$@"
  '';

  report-stale-repos = pkgs.writeShellScriptBin "report-stale-repos" ''
    export PATH=${
      bin [
        pkgs.zsh
        pkgs.glab
        pkgs.jq
        pkgs.git
        pkgs.coreutils
      ]
    }:$PATH
    exec ${zsh} ${s}/report-stale-repos "$@"
  '';

  # tr/sed strip the UTF-16 nulls wsl.exe output carries.
  get_current_wsl_distro_name = pkgs.writeShellScriptBin "get_current_wsl_distro_name" ''
    export PATH=${
      bin [
        pkgs.zsh
        pkgs.coreutils
        pkgs.gnused
      ]
    }:$PATH
    exec ${zsh} ${s}/get_current_wsl_distro_name "$@"
  '';

  # $0 yields /nix once packaged, so FLAKELAB_REPO_ROOT carries the repo root instead.
  # `nix` and `nixos-rebuild` stay on $PATH: they must be the running system's, not a
  # second copy pinned here.
  build-dev-wsl-nix = pkgs.writeShellScriptBin "build-dev-wsl-nix" ''
    export FLAKELAB_REPO_ROOT=${cfg.repoPath}
    export PATH=${
      bin [
        pkgs.zsh
        pkgs.git
        pkgs.jq
        pkgs.coreutils
        pkgs.gnugrep
        pkgs.gnused
        # setsid, so the long rebuild's null bytes go to the log, not the terminal.
        pkgs.util-linux
      ]
    }:$PATH
    exec ${zsh} ${s}/build-dev-wsl-nix "$@"
  '';

  test-provision-nix = pkgs.writeShellScriptBin "test-provision-nix" ''
    export FLAKELAB_REPO_ROOT=${cfg.repoPath}
    export PATH=${
      bin [
        pkgs.zsh
        pkgs.jq
        pkgs.coreutils
        pkgs.gnugrep
      ]
    }:$PATH
    exec ${zsh} ${s}/test-provision-nix "$@"
  '';

  # Provisioning runs powershell.exe by absolute path, and never detached: a Windows
  # process started over interop dies with the distro that launched it, so the
  # commands that restart this distro print the Windows command instead (see the
  # header of files/scripts/nix-provision).
  nix-provision = pkgs.writeShellScriptBin "nix-provision" ''
    export FLAKELAB_REPO_ROOT=${cfg.repoPath}
    export PATH=${
      bin [
        pkgs.zsh
        pkgs.coreutils
        pkgs.gnugrep
      ]
    }:$PATH
    exec ${zsh} ${s}/nix-provision "$@"
  '';

  # System-wide (nix/configuration.nix), not a `flakelab` subcommand: root runs it
  # at /run/current-system/sw/bin, from provisioning that has no user profile yet.
  # systemctl and loginctl come from $PATH first, so they talk to the running systemd;
  # the pinned copy after it only covers a caller whose PATH has none.
  switch-result = pkgs.writeShellScriptBin "flakelab-switch-result" ''
    export PATH=${
      bin [
        pkgs.zsh
        pkgs.coreutils
        pkgs.gnugrep
        pkgs.gnused
      ]
    }:$PATH:${bin [ pkgs.systemd ]}
    exec ${zsh} ${s}/switch-result "$@"
  '';

  # System-wide on the wsl target (nix/configuration.nix). rundll32.exe and wslpath
  # exist only on the ambient PATH WSL builds, so that one leads; the pinned
  # coreutils after it covers a caller whose PATH has no mktemp.
  xdg-open = pkgs.writeShellScriptBin "xdg-open" ''
    export PATH=$PATH:${bin [ pkgs.coreutils ]}
    exec ${zsh} ${s}/xdg-open "$@"
  '';

  # Update THIS distro. The repo to rebuild is repoPath, which a store path cannot
  # derive from $0, and FLAKELAB_FLAKE_ATTR names which box in it to switch into.
  # `nix-clone-repos` is pinned, because the script calls it by bare name for --all
  # and the CLI no longer puts it on PATH under that name.
  # No pkgs.openssh: the sibling sweep tools leave ssh to $PATH, so pinning one here
  # would change which ssh this uses.
  nix-update = pkgs.writeShellScriptBin "nix-update" ''
    export FLAKELAB_REPO_ROOT=${cfg.repoPath}
    export FLAKELAB_FLAKE_ATTR=${cfg.flakeAttr}
    export FLAKELAB_OVERLAY_GITIGNORE=${overlayGitignore}
    export PATH=${
      bin [
        pkgs.zsh
        pkgs.git
        pkgs.coreutils
        nix-clone-repos
        switch-result
      ]
    }:$PATH
    exec ${zsh} ${s}/nix-update "$@"
  '';

  # Same script with `--all` prepended, so the pre-flight stays in one place.
  nix-update-all = pkgs.writeShellScriptBin "nix-update-all" ''
    export FLAKELAB_REPO_ROOT=${cfg.repoPath}
    export FLAKELAB_FLAKE_ATTR=${cfg.flakeAttr}
    export FLAKELAB_OVERLAY_GITIGNORE=${overlayGitignore}
    export PATH=${
      bin [
        pkgs.zsh
        pkgs.git
        pkgs.coreutils
        nix-clone-repos
        switch-result
      ]
    }:$PATH
    exec ${zsh} ${s}/nix-update --all "$@"
  '';

  nix-backup = pkgs.writeShellScriptBin "nix-backup" ''
    export FLAKELAB_BACKUP_ROOT=${backupRoot}
    ${lib.optionalString (cfg.sopsSecretsFile != null) "export FLAKELAB_SOPS_RENDER=1"}
    ${
      # Gated at eval time, not on WSL_DISTRO_NAME: that variable is unset inside the
      # backup timer too, so a runtime gate would move every WSL payload.
      lib.optionalString (
        cfg.target != "wsl"
      ) "export FLAKELAB_INSTANCE=${lib.escapeShellArg cfg.hostName}"
    }
    ${lib.optionalString (cfg.stateRoot != null) ''
      export FLAKELAB_STATE_ROOT=${lib.escapeShellArg cfg.stateRoot}
      ${lib.optionalString cfg.stateTranscripts ''
        export FLAKELAB_STATE_TRANSCRIPTS=1
        export FLAKELAB_STATE_TRANSCRIPT_SECRETS=${cfg.stateTranscriptSecrets}
      ''}
    ''}
    # As a store path, so the gate scans with the same rules on every machine.
    export FLAKELAB_STATE_GATE_CONFIG=${../files/config/gitleaks-state.toml}
    export PATH=${
      bin [
        pkgs.zsh
        pkgs.git
        pkgs.coreutils
        pkgs.gnutar
        pkgs.gzip
        pkgs.findutils
        pkgs.gnugrep
        pkgs.diffutils
        pkgs.gawk
        pkgs.util-linux
        # Load-bearing: without gitleaks and jq the gate writes nothing to the state root.
        pkgs.gitleaks
        pkgs.jq
      ]
    }:$PATH
    exec ${zsh} ${s}/nix-backup "$@"
  '';

  # srcRoot, not `s`: the script reads templates/overlay/ and profiles/ relative to
  # itself. zsh and coreutils are the whole dependency set - the YAML reader is a
  # hand-rolled zsh parser and it never builds anything - and the suite does not guard
  # that, so re-prove it with `env -i` when the script grows an external call.
  nix-overlay-generate = pkgs.writeShellScriptBin "nix-overlay-generate" ''
    export PATH=${
      bin [
        pkgs.zsh
        pkgs.coreutils
      ]
    }:$PATH
    exec ${zsh} ${srcRoot}/files/scripts/nix-overlay-generate "$@"
  '';

  # The counts let nix-doctor tell "GitLab is broken" from "this box never used
  # GitLab", where a missing token is not a finding; the CLI list does the same for
  # an installer the overlay switched off.
  nix-doctor = pkgs.writeShellScriptBin "nix-doctor" ''
    export FLAKELAB_REPO_ROOT=${cfg.repoPath}
    export FLAKELAB_TARGET=${cfg.target}
    export FLAKELAB_OVERLAY_GITIGNORE=${overlayGitignore}
    ${lib.optionalString (cfg.stateRoot != null) ''
      export FLAKELAB_STATE_ROOT=${lib.escapeShellArg cfg.stateRoot}
    ''}
    export FLAKELAB_KIRO_PLUGIN_DIR="${kiroPluginDir}"
    export FLAKELAB_KIRO_PLUGIN_REMOTE="${kiroPluginPath}"
    export FLAKELAB_GITLAB_GROUPS="${toString (builtins.length cfg.gitlabGroups)}"
    export FLAKELAB_GITLAB_REPOS="${toString (builtins.length cfg.repos)}"
    export FLAKELAB_AI_CLIS="${
      toString (
        lib.optional cfg.installKiro "kiro-cli"
        ++ lib.optional cfg.installClaude "claude"
        ++ lib.optional cfg.installCodex "codex"
      )
    }"
    export PATH=${
      bin [
        pkgs.zsh
        pkgs.git
        pkgs.openssh
        pkgs.glab
        pkgs.jq
        pkgs.nodejs_24
        pkgs.coreutils
        pkgs.gnugrep
        pkgs.findutils
      ]
    }:$HOME/.local/bin:$PATH
    exec ${zsh} ${s}/nix-doctor "$@"
  '';

  nix-clone-repos =
    let
      groups = cfg.gitlabGroups;
      inherit (cfg) repos sshKeys;
      hasWork = groups != [ ] || repos != [ ];

      # --include-subgroups also returns projects shared INTO the group, and the "/"
      # boundary keeps sibling namespaces out. The jq keeps `.archived != true` and is
      # the only filter for the deletion-scheduled markers the API flag misses.
      # `.empty_repo` drops a project with no commits: cloning one leaves a checkout
      # the sweep reports as skipped on every later run, and it arrives as a normal
      # clone anyway once someone pushes a first commit.
      jqSelect = "select(.archived != true and .marked_for_deletion_on == null and .marked_for_deletion_at == null and .empty_repo != true and ((.namespace.full_path // \"\") | . == $group or startswith($group + \"/\")))";
      listGroup =
        g:
        "${zsh} ${s}/glab-group-projects --group ${lib.escapeShellArg g} --no-archived"
        + " | jq -r --arg group ${lib.escapeShellArg g} '${jqSelect} | .ssh_url_to_repo'";

      # Fail fast: a truncated list is indistinguishable from "those repos are gone".
      # The exclusion grep stays outside that fence, because under pipefail filtering
      # everything out looks like a failed glab call.
      discoveryBlock = lib.optionalString (groups != [ ]) ''
        : "''${GITLAB_TOKEN:?GITLAB_TOKEN not set — source ~/.config/tyc/secrets.env (from OpenBao)}"
        set -e
        {
        ${lib.concatMapStringsSep "\n        " listGroup groups}
        } > "$_raw"
        set +e

        if [ -n "$_exclude" ]; then
          # rc 1 is every repo excluded; rc >1 is a real grep failure, and reading that
          # as an empty list would silently stop cloning everything.
          grep -vE "/($_exclude)\.git$" "$_raw" > "$_list"
          _grep_rc=$?
          if [ "$_grep_rc" -gt 1 ]; then
            echo "nix-clone-repos: could not apply cloneExclude (grep rc=$_grep_rc)" >&2
            exit 2
          fi
        else
          cp "$_raw" "$_list"
        fi
      '';
      reposBlock = lib.optionalString (repos != [ ]) (
        lib.concatMapStringsSep "\n        " (r: ''echo "${r.url} $_repos/${r.relPath}" >> "$_list"'') repos
      );
      staleBlock = lib.optionalString (groups != [ ]) ''
        ${zsh} ${s}/report-stale-repos --repos-dir "$_repos" \
          ${lib.concatMapStringsSep " " (g: "--group ${lib.escapeShellArg g}") groups}
      '';
    in
    pkgs.writeShellScriptBin "nix-clone-repos" (
      if !hasWork then
        ''
          echo "nix-clone-repos: no gitlabGroups/repos configured — nothing to clone."
        ''
      else
        ''
          export PATH=${
            bin [
              pkgs.zsh
              pkgs.glab
              pkgs.jq
              pkgs.git
              pkgs.openssh
              pkgs.coreutils
              pkgs.gnugrep
            ]
          }:$PATH
          # No `set -e`: one failed clone must not skip activate-hooks.
          set -uo pipefail
          _key="$HOME/.ssh/${builtins.head sshKeys}"
          _repos="$HOME/git"
          # ERE-escaped then shell-quoted: a repo called `c++` would otherwise be an
          # alternation of metacharacters, over-matching or emptying the clone list.
          _exclude=${lib.escapeShellArg (lib.concatMapStringsSep "|" lib.escapeRegex cfg.cloneExclude)}
          _raw="$(mktemp)"
          _list="$(mktemp)"
          trap 'rm -f "$_raw" "$_list"' EXIT

          ${discoveryBlock}
          ${reposBlock}

          # Groups overlap, and two clones racing into one destination corrupt it.
          sort -u "$_list" \
            | ${zsh} ${s}/clone-repos --key-file "$_key" --repos-dir "$_repos" --max-jobs 4
          ${zsh} ${s}/activate-hooks --repos-dir "$_repos"
          ${staleBlock}
        ''
    );
}
