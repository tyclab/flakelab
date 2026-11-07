# flakelab-codex-cleanup: the user timer behind codexCleanupPeriodDays. A local Codex
# rollout past the window goes once its state-root copy is complete
# (files/scripts/codex-cleanup); while a box keeps one, the state sync's push leg
# puts it back into a state root that pruned it. Off while null.
{
  lib,
  pkgs,
  osConfig,
  flakelab,
  ...
}:
let
  cfg = osConfig.flakelab;
  inherit (flakelab) neverRestartedByActivation;
  on = cfg.codexCleanupPeriodDays != null;
  # From the flake source, as nix/scripts.nix takes it: the script sources
  # lib/state-sync.zsh beside it for the tail rule.
  cleanup = pkgs.writeShellScript "flakelab-codex-cleanup" ''
    ${lib.optionalString (cfg.stateRoot != null) ''
      export FLAKELAB_STATE_ROOT=${lib.escapeShellArg cfg.stateRoot}
    ''}
    export CODEX_CLEANUP_PERIOD_DAYS=${toString cfg.codexCleanupPeriodDays}
    export PATH=${
      lib.makeBinPath [
        pkgs.zsh
        pkgs.coreutils
        # transcript_epoch reads a rollout's tail through jq.
        pkgs.jq
        # A compressed rollout's age and plain length are read through zstd -dc.
        pkgs.zstd
      ]
    }
    exec ${pkgs.zsh}/bin/zsh ${../../files/scripts}/codex-cleanup "$@"
  '';
in
{
  assertions = [
    {
      assertion = !on || (cfg.stateRoot != null && cfg.stateTranscripts);
      message = "flakelab.codexCleanupPeriodDays needs flakelab.stateRoot and flakelab.stateTranscripts: a rollout is deleted only once its copy in the state root is complete, and without them there is none.";
    }
  ];

  systemd.user.services = lib.mkIf on {
    flakelab-codex-cleanup = lib.recursiveUpdate neverRestartedByActivation {
      Unit.Description = "flakelab: delete local Codex rollouts past codexCleanupPeriodDays whose state-root copy is complete";
      Service = {
        Type = "oneshot";
        # A tree walk and a few reads per rollout; this long is wedged, not slow.
        TimeoutStartSec = "30min";
        ExecStart = "${cleanup}";
        Nice = 19;
        IOSchedulingClass = "idle";
      };
    };
  };

  systemd.user.timers = lib.mkIf on {
    flakelab-codex-cleanup = {
      Unit.Description = "flakelab: Codex rollout cleanup (daily, ${toString cfg.codexCleanupPeriodDays} days)";
      Timer = {
        OnCalendar = "daily";
        # A box that was off at the slot catches up at its next start.
        Persistent = true;
        RandomizedDelaySec = "1h";
      };
      Install.WantedBy = [ "timers.target" ];
    };
  };
}
