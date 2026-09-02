# The `flakelab` CLI: one entrypoint in place of the fourteen per-command
# binaries that used to sit on PATH.
#
# Why this is a separate module from nix/scripts.nix: that file still builds
# every per-command wrapper, unchanged, and those wrappers are what actually
# run. This file only assembles them. The split keeps the env plumbing
# (FLAKELAB_REPO_ROOT, FLAKELAB_BACKUP_ROOT, FLAKELAB_KIRO_PLUGIN_*, and the
# per-command pinned PATH) in exactly one place, so `flakelab update` gets
# byte-identical environment to what `nix-update` got before it.
#
# The dispatch is by DIRECTORY, not by a case statement of store paths: the
# router (files/scripts/flakelab) looks up
# $FLAKELAB_DISPATCH_DIR/<wrapper-name>. That keeps the subcommand table in the
# script — one place, readable without evaluating Nix — while Nix only has to
# supply the wrappers it names.
#
# Seven of the old names squatted on the Nix ecosystem namespace (`nix-update`
# next to `nix-build`, `nix-env`, `nix-shell`); the rest were outliers
# (`build-dev-wsl-nix`, `get_current_wsl_distro_name`). gitchecker, gitcleaner
# and gitpublisher are deliberately NOT folded in: they are generic git tools
# with no namespace collision, and other repos and skills invoke them by name.
{ pkgs, cfg }:
let
  inherit (pkgs) lib;
  scripts = import ./scripts.nix { inherit pkgs cfg; };
  s = ../files/scripts;
  zsh = "${pkgs.zsh}/bin/zsh";

  # Every wrapper the router can dispatch to, under its wrapper name. The router
  # holds the subcommand -> wrapper-name mapping; this list only has to make the
  # names resolvable. Keep the two in step: a name here with no router entry is
  # dead weight, a router entry with no name here fails at run time with
  # "no executable at ...".
  dispatchDir = pkgs.symlinkJoin {
    name = "flakelab-dispatch";
    paths = [
      scripts.nix-update
      scripts.nix-update-all
      scripts.nix-doctor
      scripts.nix-backup
      scripts.claude-sessions
      scripts.nix-clone-repos
      scripts.nix-provision
      scripts.nix-overlay-generate
      scripts.build-dev-wsl-nix
      scripts.test-provision-nix
      scripts.get_current_wsl_distro_name
      scripts.clone-repos
      scripts.activate-hooks
      scripts.report-stale-repos
      scripts.glab-group-projects
    ];
  };

  # No PATH export here, deliberately. The router calls no external binary (see
  # its header), so leaving the environment untouched means each subcommand's
  # own wrapper is still the only thing that sets PATH for it — the same PATH,
  # in the same position, as when that wrapper was invoked directly.
  #
  # FLAKELAB_TARGET IS new environment, though: it is what lets the router gate
  # the four WSL-only verbs (its own sixth map) instead of every target getting
  # every verb on PATH. Unset in checkout mode (no wrapper runs there), which the
  # router treats as no gate at all — the same "can't know, so don't guess"
  # stance the doctor and backup wrappers below take on their own target reads.
  flakelab = pkgs.writeShellScriptBin "flakelab" ''
    export FLAKELAB_DISPATCH_DIR=${dispatchDir}/bin
    export FLAKELAB_TARGET=${cfg.target}
    exec ${zsh} ${s}/flakelab "$@"
  '';

  # Deprecation shims for the names an already-provisioned box's docs, aliases
  # and muscle memory still use. One line to stderr, then exec — stdout stays
  # clean, so a shim in a pipeline behaves exactly as the old command did.
  # `flakelab` by store path, not by name: a shim must work even if PATH is
  # bare. DELETE THESE next release.
  #
  # The six names an operator types, plus nix-clone-repos. That seventh one is
  # not muscle memory, it is a silent-failure guard: the pre-CLI README told
  # operators to run `nix-clone-repos` after first login, and an older copy of
  # setup-wsl-nix.ps1 calls it bare in Invoke-CloneRepos where a 127 only
  # produces a Warn — so without the shim, provisioning a current distro from an
  # old script would report success over an empty ~/git.
  #
  # The remaining plumbing (clone-repos, activate-hooks, report-stale-repos,
  # glab-group-projects, get_current_wsl_distro_name) gets no shim: nothing
  # invokes those by bare name. They are reached through sibling `${0:h}` paths
  # inside the scripts, which this refactor did not move.
  mkShim =
    old: new:
    pkgs.writeShellScriptBin old ''
      printf '%s\n' "${old}: renamed to 'flakelab ${new}', this shim goes away next release" >&2
      exec ${flakelab}/bin/flakelab ${new} "$@"
    '';

  shims = lib.mapAttrsToList mkShim {
    nix-update = "update";
    nix-doctor = "doctor";
    nix-backup = "backup";
    nix-provision = "provision";
    nix-clone-repos = "clone";
    build-dev-wsl-nix = "build-distro";
    test-provision-nix = "test-provision";
  };
in
{
  inherit flakelab shims;
}
