# Scheduled `flakelab backup`, when flakelab.backupAutostart is set.
#
# ExecStart calls the nix-backup WRAPPER by store path, not `flakelab backup`.
# Deliberate: a unit should not depend on the user's PATH, and the router would
# only add a hop to the same wrapper. The wrapper is what exports
# FLAKELAB_BACKUP_ROOT and pins the PATH, so the unit's environment is unchanged
# by the CLI refactor.
#
# This replaces a line in programs.zsh.initContent that did
# `( nix-backup --force > /dev/null 2>&1 & )` (the command is `flakelab backup`
# now), i.e. forked a FULL backup pass
# off every interactive shell start, with its output thrown away. That is a
# real behaviour change, not a move, and the honest description of it is:
#
#   before  every interactive shell, silently, however many that is per day
#   after   two minutes after the user manager starts, then every 24h
#
# It is a frequency REDUCTION. nix-backup has no rate limiter to lean on — the
# only concurrency control it has is an flock (`acquire_lock`, files/scripts/
# nix-backup:216-240: LOCK_FILE="${BACKUP_ROOT}/.backup.lock", LOCK_WAIT=300),
# and that serialises overlapping runs, it does not skip a recent one. So the
# old shape genuinely re-copied the whole payload per shell, and ten terminals
# meant ten passes queueing on that lock. A timer is the mechanism the old
# comment ("Autostart") was reaching for.
#
# Not silent any more, either: the unit's stdout/stderr land in the journal
# (`journalctl --user -u flakelab-backup`), and Type=oneshot means a non-zero
# exit — which nix-backup returns on a partial backup — is recorded as a
# failed unit instead of vanishing into /dev/null.
#
# Environment, checked rather than assumed (2026-08-21, this distro):
#   FLAKELAB_BACKUP_ROOT  exported by the nix-backup wrapper itself
#                       (nix/scripts.nix), so the unit needs nothing for it.
#   FLAKELAB_STATE_ROOT / FLAKELAB_STATE_TRANSCRIPTS
#                       exported by the same wrapper when flakelab.stateRoot /
#                       stateTranscripts are set; absent otherwise.
#   USER / HOME         present in the user manager environment
#                       (`systemctl --user show-environment`), which is what
#                       nix-backup's HOME_DIR default reads.
#   WSL_DISTRO_NAME     NOT in the user manager environment. nix-backup falls
#                       back to its sibling get_current_wsl_distro_name, which
#                       needs wsl.exe interop. Verified working from a unit:
#                       `systemd-run --user --pipe --wait \
#                          /mnt/c/Windows/system32/wsl.exe --list --running --quiet`
#                       printed the distro name, and a full
#                       `systemd-run --user … nix-backup --dry-run` resolved
#                       its destination to instances/<distro>, not
#                       instances/unknown.
#   secrets.env         not needed. nix-backup reads no token and sources no
#                       secrets file; it only COPIES ~/.config/tyc/secrets.env
#                       as payload, which needs no shell state.
#
# This module declares no activation entry. Should it ever grow one, append it
# to health.nix's flakelabHealthCheck entryAfter list (or give it
# `lib.hm.dag.entryBefore [ "flakelabHealthCheck" ]`), or the health check stops
# being the last entry and reports on work that has not run yet.
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
# backupAutostart is declared WITHOUT a default (nix/options.nix), so an overlay
# that omits it keeps aborting evaluation rather than silently defaulting to no
# backups. This is the same hard read zsh.nix did before the block moved here.
lib.optionalAttrs cfg.backupAutostart {
  systemd.user.services.flakelab-backup = {
    Unit.Description = "flakelab: back up home-dir data to the backup root";
    Service = {
      Type = "oneshot";
      # --force, as the shell autostart passed: there is no TTY here either, and
      # without it every differing file is kept and the run reports failure.
      ExecStart = "${scripts.nix-backup}/bin/nix-backup --force";
    };
  };

  systemd.user.timers.flakelab-backup = {
    Unit.Description = "flakelab: daily home-dir backup to the backup root";
    Timer = {
      # OnStartupSec is relative to the USER manager starting, which on WSL is
      # the first login to the distro — the closest equivalent of the shell
      # start this replaces, minus the once-per-terminal repetition. Two
      # minutes so it does not compete with home-manager activation.
      OnStartupSec = "2min";
      OnUnitActiveSec = "24h";
      # Jitter keeps a backup from landing on top of whatever else woke up at
      # the same moment on a backup root shared with other things (a Windows
      # disk on WSL, whatever mount a target's backupRoot names elsewhere).
      RandomizedDelaySec = "10min";
    };
    Install.WantedBy = [ "timers.target" ];
  };
}
