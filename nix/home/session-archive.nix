# The user timer behind sessionArchiveSchedule: one `session-archive run` per slot, off while it is null.
{
  lib,
  pkgs,
  osConfig,
  flakelab,
  ...
}:
let
  cfg = osConfig.flakelab;
  scripts = import ../scripts.nix { inherit pkgs cfg; };
  inherit (flakelab) neverRestartedByActivation;
  on = cfg.sessionArchiveSchedule != null;
in
{
  assertions = [
    {
      assertion =
        !on || (cfg.stateRoot != null && cfg.sessionArchiveRoot != null && cfg.sessionArchiveAreas != { });
      message = "flakelab.sessionArchiveSchedule needs flakelab.stateRoot, flakelab.sessionArchiveRoot and at least one flakelab.sessionArchiveAreas entry: a run reads the transcripts under the state root, copies each into the archive root and files its card under an area.";
    }
  ];

  systemd.user.services = lib.mkIf on {
    flakelab-session-archive = lib.recursiveUpdate neverRestartedByActivation {
      Unit.Description = "flakelab: archive quiet agent sessions and write their summary cards";
      Service = {
        Type = "oneshot";
        # Without it a wedged run parks in "activating" and blocks its own timer forever.
        TimeoutStartSec = "2h";
        ExecStart = "${scripts.session-archive}/bin/session-archive run";
        Nice = 10;
        IOSchedulingClass = "idle";
      };
    };
  };

  systemd.user.timers = lib.mkIf on {
    flakelab-session-archive = {
      Unit.Description = "flakelab: session archive run (${cfg.sessionArchiveSchedule})";
      Timer = {
        OnCalendar = cfg.sessionArchiveSchedule;
        Persistent = true;
        RandomizedDelaySec = "20min";
      };
      Install.WantedBy = [ "timers.target" ];
    };
  };
}
