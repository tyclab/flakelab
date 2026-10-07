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
