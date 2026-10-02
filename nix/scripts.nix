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
in
# `rec`, because wrappers pin sibling wrappers: nix-update and nix-update-all pin
# nix-clone-repos (the CLI keeps it off PATH under its own name, so a bare `--all`
# would trip its guard) and switch-result; web pins accounts and claude-sessions.
rec {
  mcp = (import ./mcp-clients.nix { inherit pkgs cfg; }).launcher;

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
  # ~/.local/bin holds the tools a --start window runs (the native installs of
  # Claude Code and Codex); the window gets this PATH, so a caller with
  # no login environment (the dashboard's service) still starts them.
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
    }:$HOME/.local/bin:$PATH
    exec ${zsh} ${s}/claude-sessions "$@"
  '';

  # What a bare `flakelab` opens at a terminal. stty is the one tool it runs;
  # the caller's PATH is kept aside and restored before the chosen command runs,
  # so that command's own wrapper sees the PATH a typed `flakelab <command>` has.
  flakelab-menu = pkgs.writeShellScriptBin "flakelab-menu" ''
    export FLAKELAB_CALLER_PATH="$PATH"
    export PATH=${
      bin [
        pkgs.zsh
        pkgs.coreutils
      ]
    }:$PATH
    exec ${zsh} ${s}/flakelab-menu "$@"
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

  # The dashboard: python3 from the store, the page from the store, the two
  # commands it shells out to by their wrappers so their pinned PATHs hold.
  web = pkgs.writeShellScriptBin "web" ''
    export FLAKELAB_WEB_STATIC=${../files/config/web}
    export FLAKELAB_WEB_TYCSWAP=${lib.getExe pkgs.tycswap}
    export FLAKELAB_WEB_SESSIONS=${claude-sessions}/bin/claude-sessions
    export PATH=${
      bin [
        pkgs.zsh
        pkgs.coreutils
        pkgs.python3
      ]
    }:$PATH
    exec ${zsh} ${s}/web "$@"
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

  # Run by the wsl target's activation (nix/targets/wsl.nix), at boot before systemd
  # starts, so nothing is taken from the ambient PATH: it is pinned whole.
  wsl-init-cgroup = pkgs.writeShellScriptBin "flakelab-wsl-init-cgroup" ''
    export PATH=${
      bin [
        pkgs.zsh
        pkgs.coreutils
        pkgs.gnugrep
      ]
    }
    exec ${zsh} ${s}/wsl-init-cgroup "$@"
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
    export FLAKELAB_GITLAB_GROUPS="${toString (builtins.length cfg.gitlabGroups)}"
    export FLAKELAB_GITLAB_REPOS="${toString (builtins.length cfg.repos)}"
    export FLAKELAB_AI_CLIS="${
      toString (lib.optional cfg.installClaude "claude" ++ lib.optional cfg.installCodex "codex")
    }"
    export FLAKELAB_INSTALL_TYCSWAP=${lib.boolToString cfg.installTycswap}
    export FLAKELAB_TYCSWAP_AUTOSWITCH=${lib.boolToString (cfg.tycswapAutoSwitchInterval != null)}
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
      cloneKeyResolve = import ./clone-key.nix { inherit lib sshKeys; };
      hasWork = groups != [ ] || cfg.cloneGithub || repos != [ ];

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
      discoveryBlock = lib.optionalString (groups != [ ] || cfg.cloneGithub) ''
        ${lib.optionalString (
          groups != [ ]
        ) '': "''${GITLAB_TOKEN:?GITLAB_TOKEN not set — source ~/.config/tyc/secrets.env}"''}
        set -e
        {
        ${lib.concatMapStringsSep "\n        " listGroup groups}
        ${lib.optionalString cfg.cloneGithub "${zsh} ${s}/gh-repos ${
          lib.concatMapStringsSep " " (owner: "--owner ${lib.escapeShellArg owner}") cfg.githubOwners
        }"}
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
      # No options, and every argument refused rather than ignored: an ignored
      # --help started the whole fetch-and-rebase sweep.
      argGuard = ''
        case "''${1:-}" in
          "") ;;
          -h|--help)
            echo "Usage: flakelab clone"
            echo ""
            echo "Clones configured GitLab groups, opt-in GitHub owners, and extra repos under"
            echo "~/git, fetches and rebases the clones already there, installs their"
            echo "pre-commit hooks, and reports clones whose project is archived or"
            echo "scheduled for deletion. No options: the groups, the repos and the"
            echo "exclusions come from the overlay."
            exit 0
            ;;
          *)
            echo "nix-clone-repos: takes no arguments (got '$1'); see --help" >&2
            exit 2
            ;;
        esac
      '';
      staleBlock = lib.optionalString (groups != [ ]) ''
        ${zsh} ${s}/report-stale-repos --repos-dir "$_repos" \
          ${lib.concatMapStringsSep " " (g: "--group ${lib.escapeShellArg g}") groups}
      '';
    in
    pkgs.writeShellScriptBin "nix-clone-repos" (
      if !hasWork then
        ''
          ${argGuard}
          echo "nix-clone-repos: no gitlabGroups, enabled GitHub discovery or repos — nothing to clone."
        ''
      else
        ''
          ${argGuard}
          export PATH=${
            bin [
              pkgs.zsh
              pkgs.glab
              pkgs.gh
              pkgs.jq
              pkgs.git
              pkgs.openssh
              pkgs.coreutils
              pkgs.gnugrep
            ]
          }${lib.optionalString cfg.installTycswap ":${pkgs.tycswap}/bin"}:$PATH
          # No `set -e`: one failed clone must not skip activate-hooks.
          set -uo pipefail
          # The same first-key-on-disk rule the activation steps use (nix/clone-key.nix).
          ${cloneKeyResolve}
          if [ -z "$_cloneKey" ]; then
            echo "nix-clone-repos: none of the configured sshKeys (${lib.concatStringsSep ", " sshKeys}) exists under ~/.ssh — drop one there (flakelab backup --restore puts the payload's keys back), then re-run flakelab clone." >&2
            exit 1
          fi
          _key="$_cloneKey"
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
