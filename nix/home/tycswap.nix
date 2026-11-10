{
  lib,
  pkgs,
  osConfig,
  flakelab,
  ...
}:
let
  cfg = osConfig.flakelab;
  # Timer: one `tycswap auto --once` per interval; tycswap has no engine on/off, so an installed timer is live.
  # App: tycswap's dashboard on loopback for the Windows tray (`tycswap app --remote`, installed by `flakelab tray`); no update check, the binary is this pin.
  on = cfg.installTycswap && cfg.tycswapAutoSwitchInterval != null;
  app = cfg.installTycswap && cfg.tycswapAppPort != null;
  inherit (flakelab) neverRestartedByActivation;
  # tycswap keeps its own record (every switch whoever made it, usage fetch failures, credential
  # warnings) in a private file; the journal is the record a box reads and ships, so it is followed.
  # journald takes a leading <N> as the line's priority.
  logLevels = pkgs.writeShellScript "flakelab-tycswap-log-levels" ''
    while IFS= read -r line; do
      case $line in
        *' - ERROR - '*) printf '<3>%s\n' "$line" ;;
        *' - WARNING - '*) printf '<4>%s\n' "$line" ;;
        *) printf '<6>%s\n' "$line" ;;
      esac
    done
  '';
  # -F follows the name across tycswap's rotation and waits for a file not written yet; -n 0 because
  # the journal already holds what an earlier run followed.
  logFollower = pkgs.writeShellScript "flakelab-tycswap-log" ''
    ${pkgs.coreutils}/bin/tail -F -n 0 "$HOME/.local/share/tycswap/tycswap.log" | ${logLevels}
  '';
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
    lib.optionalAttrs cfg.installTycswap {
      flakelab-tycswap-log = {
        Unit.Description = "flakelab: tycswap's log in the journal";
        Service = {
          ExecStart = "${logFollower}";
          SyslogIdentifier = "tycswap";
          Restart = "always";
          RestartSec = "5s";
        };
        Install.WantedBy = [ "default.target" ];
      };
    }
    // lib.optionalAttrs on {
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
          # The timer owns rotation: dashboard/tray starts are rejected server-side, a remembered hosted engine included.
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
