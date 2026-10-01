# The auto-switch timer for `flakelab accounts` (accounts.md, "Auto-switch"):
# one `accounts auto --once` per interval, deciding for the tools
# flakelab.accounts.autoSwitchTools names. The engine keeps its state in the
# store between ticks, so there is no long-running process to lose. The timer
# is on every box, so `flakelab accounts auto on` needs no rebuild: without
# autoSwitchInterval it ticks every 2 minutes and auto-switch starts off, and an
# off tick is one short process that reads a file. ExecStart calls the wrapper
# by store path, since a unit must not depend on the user's PATH.
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
  interval =
    if cfg.accounts.autoSwitchInterval != null then cfg.accounts.autoSwitchInterval else "2min";
in
{
  # A file read, not `flakelab accounts`: that runs ~46 processes and, when an
  # entry is due, a network poll before the prompt appears.
  programs.zsh.initContent = lib.mkIf cfg.accounts.shellOverview (
    lib.mkAfter ''
      if [[ -o interactive && -t 1 && -r "$HOME/.local/state/flakelab/accounts/overview.txt" ]]; then
        print -r -- "$(<"$HOME/.local/state/flakelab/accounts/overview.txt")"
      fi
    ''
  );

  systemd.user.services = {
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

  systemd.user.timers = {
    flakelab-accounts-autoswitch = {
      Unit.Description = "flakelab: auto-switch tick every ${interval}";
      Timer = {
        OnStartupSec = "2min";
        OnUnitActiveSec = interval;
      };
      Install.WantedBy = [ "timers.target" ];
    };
  };
}
