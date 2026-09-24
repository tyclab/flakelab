# The auto-switch timer for `flakelab accounts` (accounts.md, "Auto-switch"):
# one `accounts auto --once` per interval, deciding for the tools
# flakelab.accounts.autoSwitchTools names. The engine keeps its state in the
# store between ticks, so there is no long-running process to lose. Off unless
# autoSwitchInterval is set. ExecStart calls the wrapper by store path, since a
# unit must not depend on the user's PATH.
{
  lib,
  pkgs,
  osConfig,
  ...
}:
let
  cfg = osConfig.flakelab;
  scripts = import ../scripts.nix { inherit pkgs cfg; };
  auto = cfg.accounts.autoSwitchInterval != null;
  neverRestartedByActivation = {
    Unit."X-RestartIfChanged" = false;
    Service."X-RestartIfChanged" = false;
  };
in
{
  systemd.user.services = lib.optionalAttrs auto {
    flakelab-accounts-autoswitch = lib.recursiveUpdate neverRestartedByActivation {
      Unit.Description = "flakelab: switch the live agent login before it hits a rate limit";
      Service = {
        Type = "oneshot";
        # A tick is a few usage requests and at most one switch.
        TimeoutStartSec = "3min";
        ExecStart = "${scripts.accounts}/bin/accounts auto --once --json";
        Nice = 10;
      };
    };
  };

  systemd.user.timers = lib.optionalAttrs auto {
    flakelab-accounts-autoswitch = {
      Unit.Description = "flakelab: auto-switch tick every ${cfg.accounts.autoSwitchInterval}";
      Timer = {
        OnStartupSec = "2min";
        OnUnitActiveSec = cfg.accounts.autoSwitchInterval;
      };
      Install.WantedBy = [ "timers.target" ];
    };
  };
}
