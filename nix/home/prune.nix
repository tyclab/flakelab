# flakelab-prune: what grows without bound and nothing else trims — the Codex
# releases its installer keeps, uv's and pre-commit's caches. Docker's half is
# virtualisation.docker.autoPrune on the same pruneSchedule.
{
  lib,
  pkgs,
  osConfig,
  flakelab,
  ...
}:
let
  cfg = osConfig.flakelab;
  inherit (flakelab) installCodex neverRestartedByActivation;
  prune = pkgs.writeShellScript "flakelab-prune" ''
    set -uo pipefail
    export PATH="${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.procps
        pkgs.uv
        pkgs.pre-commit
      ]
    }"
    ${lib.optionalString installCodex ''
      # ~430 MB a release, one a day at times. A live codex may still run an older
      # one, so any running codex skips the pass.
      if ! pgrep -u "$(id -u)" -x codex > /dev/null; then
        for pkg in "$HOME"/.codex/packages/*/; do
          [ -L "''${pkg}current" ] || continue
          cur="$(readlink -f "''${pkg}current")" && [ -d "$cur" ] || continue
          for rel in "''${pkg}"releases/*/; do
            [ -d "$rel" ] || continue
            [ "$(readlink -f "$rel")" = "$cur" ] || rm -rf -- "$rel"
          done
        done
      fi
    ''}
    uv cache prune || true
    pre-commit gc || true
  '';
in
lib.mkIf (cfg.pruneSchedule != null) {
  systemd.user.services.flakelab-prune = lib.recursiveUpdate neverRestartedByActivation {
    Unit.Description = "flakelab: prune old Codex releases and the uv and pre-commit caches";
    Service = {
      Type = "oneshot";
      Nice = 19;
      ExecStart = "${prune}";
    };
  };
  systemd.user.timers.flakelab-prune = {
    Unit.Description = "flakelab: prune Codex releases and tool caches (${cfg.pruneSchedule})";
    Timer = {
      OnCalendar = cfg.pruneSchedule;
      # A box that was off at the slot catches up at its next start.
      Persistent = true;
      RandomizedDelaySec = "1h";
    };
    Install.WantedBy = [ "timers.target" ];
  };
}
