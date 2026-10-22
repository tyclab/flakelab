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
        pkgs.gnugrep
        pkgs.uv
        pkgs.pre-commit
      ]
    }"
    ${lib.optionalString installCodex ''
      # ~430 MB a release, one a day at times. Sessions outlive an update, so the
      # releases a running process executes from stay with the current one.
      running="$(for pid in /proc/[0-9]*; do readlink "$pid/exe" 2> /dev/null; done)"
      for pkg in "$HOME"/.codex/packages/*/; do
        [ -L "''${pkg}current" ] || continue
        cur="$(readlink -f "''${pkg}current")" && [ -d "$cur" ] || continue
        for rel in "''${pkg}"releases/*/; do
          [ -d "$rel" ] || continue
          real="$(readlink -f "$rel")"
          [ "$real" = "$cur" ] && continue
          printf '%s\n' "$running" | grep -q -F -- "$real/" && continue
          rm -rf -- "$rel"
        done
      done
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
