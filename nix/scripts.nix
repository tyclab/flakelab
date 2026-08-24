# Wrappers around files/scripts, with a pinned PATH each.
#
# `cfg` is the flakelab option set (nix/options.nix) — the callers in nix/home/
# pass `osConfig.flakelab`. The fields read here are repoPath, username,
# kiroPluginRepo, gitlabGroups, repos, sshKeys, cloneExclude, stateRoot and
# stateTranscripts; every one has its type and default declared there, which
# is why nothing below needs an `or` fallback any more.
{ pkgs, cfg }:
let
  inherit (pkgs) lib;
  # From the flake source, not repoPath: a private overlay sets repoPath to its
  # own dir, which has no files/scripts.
  s = ../files/scripts;
  # For nix-overlay-generate alone. `s` above is a store path of its own holding
  # only files/scripts, so from a script in it `${0:A:h:h:h}` is `/nix` — fine
  # for the scripts that use that only as a fallback, fatal for
  # nix-overlay-generate, which REQUIRES templates/overlay/ and profiles/ next
  # to itself and dies when they are not there.
  #
  # So it needs a store path shaped like the repo root. `../.` would give one,
  # but it materialises a SECOND full copy of the tree (a path literal naming a
  # subtree of the flake source is copied afresh — that is also why `s` above is
  # its own `-scripts` path rather than a subpath of the source). fileset ships
  # only the three things the script actually reads, at their repo-relative
  # positions, so `${0:A:h:h:h}` still lands on the root:
  #   files/scripts/nix-overlay-generate  the script itself (it sources no lib)
  #   templates/overlay/                  read at line 130
  #   profiles/*.nix                      read at line 620
  # Add to this list if the script learns to read anything else from its
  # checkout, or it will die in installed mode while checkout mode stays green.
  srcRoot = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../files/scripts/nix-overlay-generate
      ../templates/overlay
      ../profiles
    ];
  };
  zsh = "${pkgs.zsh}/bin/zsh";
  bin = lib.makeBinPath;
  # Backups must land on the Windows mount to survive distro re-provisioning.
  backupRoot = "${cfg.repoPath}/files/config";
  # The optional state root is exported by the nix-backup wrapper below only
  # when set; the script treats an unset variable as "everything stays in the
  # payload".
  # nix-doctor measures the kiro-plugin checkout against these — the same
  # derivation nix/home/default.nix clones into, so an overlay that overrides
  # kiroPluginRepo is not diagnosed against a path no activation ever writes.
  kiroPlugin = import ./kiro-plugin.nix { inherit lib cfg; };
  kiroPluginPath = kiroPlugin.path;
  kiroPluginDir = kiroPlugin.dir;
in
# `rec` for exactly one self-reference: the nix-update / nix-update-all wrappers
# pin `nix-clone-repos` into their own PATH. They used to inherit it from the
# caller's PATH, which worked only while nix-clone-repos was itself in
# home.packages. The flakelab CLI took it off PATH (nix/cli.nix), so `--all`
# would have hit nix-update's "not on PATH" guard on every run. There is no
# cycle: nix-clone-repos references none of the other attributes.
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

  # jq/glab/gh pinned alongside git: every sweep parses forge JSON, and gh is
  # probed lazily only when the scanned tree holds a github.com remote.
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

  # The mutating half of the sweep: retires branches and worktree entries whose
  # work has landed. Same discovery and forge routing as gitchecker via
  # files/scripts/lib/gitscan.zsh; glab/jq/gh ride in from home.packages.
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

  # The publish half of glab work: branch, commit through the hooks, push,
  # open the MR — every gate in the tool rather than in an agent's prompt.
  # No gh: GitLab-only by design; the script refuses other forges itself.
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

  # Only ever called from inside nix-clone-repos, so their diagnostics were
  # unreachable for an operator debugging a discovery gap by hand.
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

  # Shells out to /mnt/c/Windows/system32/wsl.exe by absolute path; needs tr/sed
  # to strip the UTF-16 nulls that output carries.
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

  # Both drive distro lifecycle from inside a distro and used to be reachable only
  # by path, because they derived the repo root from $0 and a store path made that
  # /nix. FLAKELAB_REPO_ROOT carries it from repoPath instead, so wrapping them is
  # what makes them usable at all.
  #
  # `nix` and `nixos-rebuild` are intentionally left to $PATH: they must be the
  # running system's, not a second copy pinned by this wrapper.
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
        # setsid: detaches the long nixos-rebuild call from the controlling
        # terminal (known-issues.md), so its null bytes go to the log only.
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

  # Provisioning is driven from Windows, so from in here it means powershell.exe
  # with an absolute drive path, and a detached run for anything that ends in
  # `wsl --shutdown` - which kills the shell that started it. This wrapper is the
  # whole point: nobody should have to remember `setsid`.
  nix-provision = pkgs.writeShellScriptBin "nix-provision" ''
    export FLAKELAB_REPO_ROOT=${cfg.repoPath}
    export PATH=${
      bin [
        pkgs.zsh
        pkgs.coreutils
        pkgs.gnugrep
        # setsid, so the run outlives the shell the shutdown takes with it.
        pkgs.util-linux
      ]
    }:$PATH
    exec ${zsh} ${s}/nix-provision "$@"
  '';

  # Update THIS distro. Was a set of zsh functions in programs.zsh.initContent;
  # the wrapper is what makes the script form work at all, because the repo to
  # rebuild is repoPath (an overlay's own flake) and a store path cannot derive
  # it from $0 — the same reason build-dev-wsl-nix and nix-provision export
  # FLAKELAB_REPO_ROOT.
  #
  # `sudo` and `nixos-rebuild` are intentionally left to $PATH for the reason
  # spelled out at build-dev-wsl-nix above: the rebuild must be the running
  # system's, not a second copy pinned here. The prepend keeps the caller's
  # $PATH intact.
  #
  # `nix-clone-repos` IS pinned, and used not to be. The script calls it by bare
  # name for --all and guards with `command -v`; that resolved from the caller's
  # PATH only while nix-clone-repos sat in home.packages under its own name.
  # `flakelab clone` replaced it there, so without this pin `--all` would report
  # "nix-clone-repos is not on PATH" after every successful switch. Pinning the
  # derivation keeps the script body, its guard and its message untouched.
  #
  # No pkgs.openssh either, deliberately. The fetch does set GIT_SSH_COMMAND
  # (via lib/git-net.zsh), but gitchecker/gitcleaner/gitpublisher fetch the same
  # way and also leave ssh to $PATH — and this code ran as a shell function
  # against the caller's ssh until now, so pinning one here would CHANGE which
  # ssh it uses rather than preserve it. A bare env fails loudly (gitnet_retry
  # prints GITNET_WHY), it does not fail silently.
  nix-update = pkgs.writeShellScriptBin "nix-update" ''
    export FLAKELAB_REPO_ROOT=${cfg.repoPath}
    export PATH=${
      bin [
        pkgs.zsh
        pkgs.git
        pkgs.coreutils
        nix-clone-repos
      ]
    }:$PATH
    exec ${zsh} ${s}/nix-update "$@"
  '';

  # Same script, `--all` prepended: rebuild, then re-run the clone sweep. A
  # second wrapper rather than a second script keeps the pre-flight in one
  # place while both names stay callable exactly as the shell functions were.
  nix-update-all = pkgs.writeShellScriptBin "nix-update-all" ''
    export FLAKELAB_REPO_ROOT=${cfg.repoPath}
    export PATH=${
      bin [
        pkgs.zsh
        pkgs.git
        pkgs.coreutils
        nix-clone-repos
      ]
    }:$PATH
    exec ${zsh} ${s}/nix-update --all "$@"
  '';

  nix-backup = pkgs.writeShellScriptBin "nix-backup" ''
    export FLAKELAB_BACKUP_ROOT=${backupRoot}
    ${lib.optionalString (cfg.stateRoot != null) ''
      export FLAKELAB_STATE_ROOT=${lib.escapeShellArg cfg.stateRoot}
      ${lib.optionalString cfg.stateTranscripts "export FLAKELAB_STATE_TRANSCRIPTS=1"}
    ''}
    # The secret gate's rule set, as a store path: the gate scans with the same
    # rules on every machine, and a checkout run is the only case that has to
    # fall back to the file in the repo.
    export FLAKELAB_STATE_GATE_CONFIG=${../files/config/gitleaks-state.toml}
    export PATH=${
      bin [
        pkgs.zsh
        pkgs.git
        pkgs.coreutils
        pkgs.gnutar
        # gnutar shells out for -z; the rollback snapshots are .tar.gz.
        pkgs.gzip
        pkgs.findutils
        pkgs.gnugrep
        pkgs.diffutils
        pkgs.gawk
        # flock, for the lock that stops two runs interleaving payload writes.
        pkgs.util-linux
        # The secret gate: gitleaks scans, jq reads its report. Missing either,
        # the gate writes NOTHING to the state root — so these are load-bearing,
        # not conveniences.
        pkgs.gitleaks
        pkgs.jq
      ]
    }:$PATH
    exec ${zsh} ${s}/nix-backup "$@"
  '';

  # NEW on PATH with the flakelab CLI (`flakelab overlay-gen`); until now this
  # script was checkout-only, because it reads templates/overlay/ and profiles/
  # from `${0:A:h:h:h}` and every other wrapper here resolves that to `/nix`.
  # Hence srcRoot rather than `s`: a store path shaped like the repo root, so
  # both directories are where the script already looks, with no change to the
  # script itself. Running `./files/scripts/nix-overlay-generate` from a
  # checkout still reads THAT checkout's templates — this wrapper only adds the
  # installed-flake path, it does not replace the checkout one.
  #
  # zsh and coreutils only, and that is the whole dependency set: the YAML
  # reader is a hand-rolled zsh parser (no yq), and the only external calls in
  # the script are mkdir/chmod/mv/cat. No `nix` either — it writes an overlay,
  # it never builds one. Verified by running this wrapper with `env -i` and
  # nothing but the two directories below on PATH: it generated a complete
  # overlay from files/config/user_data.example.yaml and exited 0.
  #
  # Note that test-nix-overlay-generate does NOT guard this list: the flake
  # check gives the suite zsh/git/jq/util-linux on top of stdenv, a superset, so
  # a newly added dependency would pass there and only fail here. Re-run the
  # `env -i` check above when this script grows an external call.
  nix-overlay-generate = pkgs.writeShellScriptBin "nix-overlay-generate" ''
    export PATH=${
      bin [
        pkgs.zsh
        pkgs.coreutils
      ]
    }:$PATH
    exec ${zsh} ${srcRoot}/files/scripts/nix-overlay-generate "$@"
  '';

  # The GitLab counts are what let nix-doctor tell "GitLab is broken" from "this
  # box was never configured for GitLab": with no groups and no explicit repos,
  # nothing on this distro ever calls glab or clones over git@gitlab.com, so a
  # missing token or a failed auth probe is not a finding.
  nix-doctor = pkgs.writeShellScriptBin "nix-doctor" ''
    export FLAKELAB_REPO_ROOT=${cfg.repoPath}
    export FLAKELAB_KIRO_PLUGIN_DIR="${kiroPluginDir}"
    export FLAKELAB_KIRO_PLUGIN_REMOTE="${kiroPluginPath}"
    export FLAKELAB_GITLAB_GROUPS="${toString (builtins.length cfg.gitlabGroups)}"
    export FLAKELAB_GITLAB_REPOS="${toString (builtins.length cfg.repos)}"
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

      # --include-subgroups also returns projects shared INTO the group; only those
      # under $group belong. The "/" boundary keeps sibling namespaces ("$group-hub")
      # out, since .namespace.full_path carries no trailing separator — the same
      # anchor report-stale-repos applies to .path_with_namespace.
      # glab-group-projects paginates and emits one project object per line.
      # --no-archived drops archived projects server-side; the jq keeps
      # `.archived != true` as a belt (the flag is opt-in and could regress
      # silently) and remains the only filter for the deletion-scheduled
      # markers, which the API flag does not cover.
      jqSelect = "select(.archived != true and .marked_for_deletion_on == null and .marked_for_deletion_at == null and ((.namespace.full_path // \"\") | . == $group or startswith($group + \"/\")))";
      listGroup =
        g:
        "${zsh} ${s}/glab-group-projects --group ${lib.escapeShellArg g} --no-archived"
        + " | jq -r --arg group ${lib.escapeShellArg g} '${jqSelect} | .ssh_url_to_repo'";

      # Fail-fast: a truncated list is indistinguishable from "those repos are
      # gone" and would silently stop cloning them. The exclusion grep stays
      # outside that fence — under pipefail, filtering everything out looks the
      # same as a failed glab call. Only discovery needs the token.
      discoveryBlock = lib.optionalString (groups != [ ]) ''
        : "''${GITLAB_TOKEN:?GITLAB_TOKEN not set — source ~/.config/tyc/secrets.env (from OpenBao)}"
        set -e
        {
        ${lib.concatMapStringsSep "\n        " listGroup groups}
        } > "$_raw"
        set +e

        if [ -n "$_exclude" ]; then
          # rc 1 is legitimate here — every discovered repo was excluded. rc >1 is
          # a real grep failure, and treating it as an empty list would silently
          # stop cloning everything (same rule as clone-repos' ledger rewrite).
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
      # Explicit repos bypass cloneExclude: naming one here is already explicit.
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
          # No global set -e: one repo failing to clone must not skip activate-hooks.
          set -uo pipefail
          _key="$HOME/.ssh/${builtins.head sshKeys}"
          _repos="$HOME/git"
          # ERE-escaped per name, then shell-quoted: a repo called `c++` or
          # `foo.bar` would otherwise be an alternation of regex metacharacters —
          # over-matching quietly, or making grep exit 2 and (with the old
          # `|| true`) hand back an EMPTY clone list.
          _exclude=${lib.escapeShellArg (lib.concatMapStringsSep "|" lib.escapeRegex cfg.cloneExclude)}
          _raw="$(mktemp)"
          _list="$(mktemp)"
          trap 'rm -f "$_raw" "$_list"' EXIT

          ${discoveryBlock}
          ${reposBlock}

          # Groups overlap (a parent contains its subgroups), and two clones
          # racing into one destination corrupt it.
          sort -u "$_list" \
            | ${zsh} ${s}/clone-repos --key-file "$_key" --repos-dir "$_repos" --max-jobs 4
          ${zsh} ${s}/activate-hooks --repos-dir "$_repos"
          ${staleBlock}
        ''
    );
}
