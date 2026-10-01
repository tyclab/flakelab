# The auto-switch timer: one `tycswap auto --once` per interval, deciding for
# every tool tycswap holds logins of. tycswap keeps its state in its store
# between ticks, so there is no long-running process to lose, and a tick with
# nothing over a threshold is one short process (exit 2, "no action"). The
# timer exists only when flakelab.tycswapAutoSwitchInterval is set: unlike the
# retired engine, tycswap has no engine-level on/off, so an installed timer is
# a live one. ExecStart names the binary by store path, since a unit must not
# depend on the user's PATH; getExe follows the pinned release's main program.
{
  lib,
  pkgs,
  osConfig,
  flakelab,
  ...
}:
let
  cfg = osConfig.flakelab;
  on = cfg.installTycswap && cfg.tycswapAutoSwitchInterval != null;
  inherit (flakelab) neverRestartedByActivation;
in
{
  assertions = [
    {
      assertion = cfg.tycswapAutoSwitchInterval == null || cfg.installTycswap;
      message = "flakelab.tycswapAutoSwitchInterval needs flakelab.installTycswap = true: the timer runs tycswap.";
    }
  ];

  systemd.user.services = lib.mkIf on {
    flakelab-tycswap-autoswitch = lib.recursiveUpdate neverRestartedByActivation {
      Unit.Description = "flakelab: tycswap moves the live agent login before it hits a rate limit";
      Service = {
        Type = "oneshot";
        # A tick is a few usage requests and at most one switch per tool.
        TimeoutStartSec = "3min";
        ExecStart = "${lib.getExe pkgs.tycswap} auto --once --json";
        # tycswap's "no action" (2) and "blocked" (3) are outcomes, not failures.
        SuccessExitStatus = "2 3";
        Nice = 10;
      };
    };
  };

  systemd.user.timers = lib.mkIf on {
    flakelab-tycswap-autoswitch = {
      Unit.Description = "flakelab: tycswap auto-switch tick every ${cfg.tycswapAutoSwitchInterval}";
      Timer = {
        OnStartupSec = "2min";
        OnUnitActiveSec = cfg.tycswapAutoSwitchInterval;
      };
      Install.WantedBy = [ "timers.target" ];
    };
  };
}
