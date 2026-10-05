# The auto-switch timer: one `tycswap auto --once` per interval, deciding for
# every tool tycswap holds logins of. tycswap keeps its state in its store
# between ticks, so there is no long-running process to lose, and a tick with
# nothing over a threshold is one short process (exit 2, "no action"). The
# timer exists only when flakelab.tycswapAutoSwitchInterval is set: unlike the
# retired engine, tycswap has no engine-level on/off, so an installed timer is
# a live one. ExecStart names the binary by store path, since a unit must not
# depend on the user's PATH; getExe follows the pinned release's main program.
#
# The headless app (flakelab.tycswapAppPort): tycswap's dashboard on loopback
# for the Windows tray, which is tycswap's own binary on the host driving it
# through WSL2's localhost forwarding (`tycswap app --remote`). It follows the
# activation, unlike flakelab-web: a new pin restarts it onto the new binary,
# and the tray re-reads the per-start token the app writes next to its store.
# No update check: the binary is this flake's pin, which tycswap will not
# replace, so the badge the check feeds would never be actionable here.
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
  app = cfg.installTycswap && cfg.tycswapAppPort != null;
  inherit (flakelab) neverRestartedByActivation;
in
{
  assertions = [
    {
      assertion = cfg.tycswapAutoSwitchInterval == null || cfg.installTycswap;
      message = "flakelab.tycswapAutoSwitchInterval needs flakelab.installTycswap = true: the timer runs tycswap.";
    }
    {
      assertion = cfg.tycswapAppPort == null || cfg.installTycswap;
      message = "flakelab.tycswapAppPort needs flakelab.installTycswap = true: the service runs tycswap.";
    }
  ];

  systemd.user.services =
    lib.optionalAttrs on {
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
    }
    // lib.optionalAttrs app {
      flakelab-tycswap-app = {
        Unit.Description = "flakelab: tycswap's dashboard on 127.0.0.1:${toString cfg.tycswapAppPort} for the Windows tray";
        Service = {
          ExecStart = "${lib.getExe pkgs.tycswap} app --headless --port ${toString cfg.tycswapAppPort} --no-update-check";
          # The timer owns rotation. Reject dashboard/tray starts server-side,
          # including a remembered hosted engine from an earlier app run.
          Environment = lib.optional on "TYCSWAP_AUTO_MANAGED_BY=flakelab-tycswap-autoswitch.timer";
          Restart = "on-failure";
          RestartSec = "5s";
        };
        Install.WantedBy = [ "default.target" ];
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
