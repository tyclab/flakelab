# User timers, each behind its own switch: flakelab-backup (daily full pass), flakelab-state-sync (`--state-only`,
# independent of backupAutostart), flakelab-sessions-autosave. ExecStart uses store paths, never the user's PATH.
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
  # Only --state-only is safe sub-daily: a full pass re-snapshots the payload and
  # would burn the snapshot ring down to hours of rollback.
  stateSync = cfg.stateRoot != null && cfg.stateSyncInterval != null;
  autosave = cfg.sessionsAutosaveInterval != null;
in
{
  systemd.user.services =
    lib.optionalAttrs cfg.backupAutostart {
      flakelab-backup = lib.recursiveUpdate neverRestartedByActivation {
        Unit.Description = "flakelab: back up home-dir data to the backup root";
        Service = {
          Type = "oneshot";
          # Without it a wedged run parks in "activating" and blocks its own timer forever.
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
    }
    // lib.optionalAttrs autosave {
      flakelab-sessions-autosave = lib.recursiveUpdate neverRestartedByActivation {
        Unit.Description = "flakelab: snapshot the running Claude Code sessions for crash recovery";
        Service = {
          Type = "oneshot";
          # pgrep, a few registry reads and at most one small file.
          TimeoutStartSec = "2min";
          ExecStart = "${scripts.claude-sessions}/bin/claude-sessions --autosave";
          Nice = 10;
        };
      };
    };

  systemd.user.timers =
    lib.optionalAttrs cfg.backupAutostart {
      flakelab-backup = {
        Unit.Description = "flakelab: daily home-dir backup to the backup root";
        Timer = {
          # After user-manager start, late enough not to compete with home-manager activation.
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
    }
    // lib.optionalAttrs autosave {
      flakelab-sessions-autosave = {
        Unit.Description = "flakelab: Claude Code session snapshot every ${cfg.sessionsAutosaveInterval}";
        Timer = {
          # Early: sessions opened right after login are the ones a crash would otherwise lose.
          OnStartupSec = "1min";
          OnUnitActiveSec = cfg.sessionsAutosaveInterval;
        };
        Install.WantedBy = [ "timers.target" ];
      };
    };
}
