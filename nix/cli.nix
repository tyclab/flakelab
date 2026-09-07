# The `flakelab` CLI: assembles the per-command wrappers nix/scripts.nix builds into
# one dispatch directory the router (files/scripts/flakelab) looks names up in.
# gitchecker, gitcleaner and gitpublisher stay standalone: other repos invoke them.
{ pkgs, cfg }:
let
  inherit (pkgs) lib;
  scripts = import ./scripts.nix { inherit pkgs cfg; };
  s = ../files/scripts;
  zsh = "${pkgs.zsh}/bin/zsh";

  # Keep in step with the router's subcommand map: an entry it names but this list
  # does not fails at run time with "no executable at ...".
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

  # No PATH export: each subcommand's own wrapper stays the only thing that sets it.
  # FLAKELAB_TARGET lets the router gate the WSL-only verbs; unset means no gate.
  flakelab = pkgs.writeShellScriptBin "flakelab" ''
    export FLAKELAB_DISPATCH_DIR=${dispatchDir}/bin
    export FLAKELAB_TARGET=${cfg.target}
    exec ${zsh} ${s}/flakelab "$@"
  '';

  # Deprecation shims for the old command names; warn on stderr only, so a shim in
  # a pipeline behaves as the old command did. Delete these next release.
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
