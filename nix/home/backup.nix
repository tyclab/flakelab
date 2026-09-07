# Timers for `flakelab backup` when backupAutostart is set: the daily full pass and
# the short-interval `--state-only` sync. ExecStart calls the nix-backup wrapper by
# store path, since a unit must not depend on the user's PATH.
{
  lib,
  pkgs,
  osConfig,
  ...
}:
let
  cfg = osConfig.flakelab;
  scripts = import ../scripts.nix { inherit pkgs cfg; };
in
lib.optionalAttrs cfg.backupAutostart (
  let
    # Only --state-only is safe sub-daily: a full pass re-snapshots the payload and
    # would burn the snapshot ring down to hours of rollback.
    stateSync = cfg.stateRoot != null && cfg.stateSyncInterval != null;
  in
  {
    systemd.user.services =
      let
        # Activation must never restart these oneshots: it would block on a running
        # pass until home-manager times out, or kill a sync mid-copy. Both sections,
        # because sd-switch reads [Unit] and switch-to-configuration reads [Service].
        neverRestartedByActivation = {
          Unit."X-RestartIfChanged" = false;
          Service."X-RestartIfChanged" = false;
        };
      in
      {
        flakelab-backup = lib.recursiveUpdate neverRestartedByActivation {
          Unit.Description = "flakelab: back up home-dir data to the backup root";
          Service = {
            Type = "oneshot";
            # Without this a wedged run parks in "activating" and blocks its own
            # timer forever.
            TimeoutStartSec = "2h";
            # --force: no TTY here, so without it every differing file is kept and
            # the run reports failure.
            ExecStart = "${scripts.nix-backup}/bin/nix-backup --force";
          };
        };
      }
      // lib.optionalAttrs stateSync {
        flakelab-state-sync = lib.recursiveUpdate neverRestartedByActivation {
          Unit.Description = "flakelab: two-way state-root sync (history, memory, transcripts)";
          Service = {
            Type = "oneshot";
            # A state-only pass this long is wedged, not slow.
            TimeoutStartSec = "30min";
            ExecStart = "${scripts.nix-backup}/bin/nix-backup --state-only --force";
            # Never compete with interactive work on the box being copied.
            Nice = 10;
            IOSchedulingClass = "idle";
          };
        };
      };

    systemd.user.timers = {
      flakelab-backup = {
        Unit.Description = "flakelab: daily home-dir backup to the backup root";
        Timer = {
          # Relative to user-manager start (first login on WSL), late enough not to
          # compete with home-manager activation.
          OnStartupSec = "2min";
          OnUnitActiveSec = "24h";
          # Jitter: the backup root is shared with whatever else wakes up then.
          RandomizedDelaySec = "10min";
        };
        Install.WantedBy = [ "timers.target" ];
      };
    }
    // lib.optionalAttrs stateSync {
      flakelab-state-sync = {
        Unit.Description = "flakelab: state-root sync every ${cfg.stateSyncInterval}";
        Timer = {
          # After the full backup's login slot, so the two never race for the lock.
          OnStartupSec = "5min";
          OnUnitActiveSec = cfg.stateSyncInterval;
          # Keeps two machines' timers from meeting at the shared root every period.
          RandomizedDelaySec = "3min";
        };
        Install.WantedBy = [ "timers.target" ];
      };
    };
  }
)
