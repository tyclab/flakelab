# flakelab-prune: what grows without bound and nothing else trims — the Codex
# releases its installer keeps, uv's and pre-commit's caches, and the toolchain and
# model caches a build fills and nothing reads between builds. Docker's half is
# virtualisation.docker.autoPrune on the same pruneSchedule.
{
  lib,
  pkgs,
  osConfig,
  flakelab,
  ...
}:
let
  cfg = osConfig.flakelab;
  inherit (flakelab) installCodex neverRestartedByActivation;
  prune = pkgs.writeShellScript "flakelab-prune" ''
    set -uo pipefail
    export PATH="${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.findutils
        pkgs.gnugrep
        pkgs.uv
        pkgs.pre-commit
      ]
    }"
    # What a live process executes from or holds open stays, whatever its age.
    running="$(for pid in /proc/[0-9]*; do readlink "$pid/exe" "$pid"/fd/* 2> /dev/null; done)"
    ${lib.optionalString installCodex ''
      # ~430 MB a release, one a day at times. Sessions outlive an update, so the
      # releases a running process executes from stay with the current one.
      for pkg in "$HOME"/.codex/packages/*/; do
        [ -L "''${pkg}current" ] || continue
        cur="$(readlink -f "''${pkg}current")" && [ -d "$cur" ] || continue
        for rel in "''${pkg}"releases/*/; do
          [ -d "$rel" ] || continue
          real="$(readlink -f "$rel")"
          [ "$real" = "$cur" ] && continue
          printf '%s\n' "$running" | grep -q -F -- "$real/" && continue
          rm -rf -- "$rel"
        done
      done
    ''}
    # PlatformIO toolchains and Hugging Face models: gigabytes a firmware build or an
    # embedding run downloads and nothing reads in between. Gone once nothing in them
    # was written for 30 days; the next build downloads what it needs again.
    for cache in "$HOME/.platformio" "$HOME/.cache/huggingface"; do
      [ -d "$cache" ] || continue
      [ -n "$(find "$cache" -type f -mtime -30 -print -quit)" ] && continue
      printf '%s\n' "$running" | grep -q -F -- "$cache/" && continue
      rm -rf -- "$cache"
    done
    uv cache prune || true
    pre-commit gc || true
  '';
in
lib.mkIf (cfg.pruneSchedule != null) {
  systemd.user.services.flakelab-prune = lib.recursiveUpdate neverRestartedByActivation {
    Unit.Description = "flakelab: prune old Codex releases, the uv and pre-commit caches and stale toolchain and model caches";
    Service = {
      Type = "oneshot";
      Nice = 19;
      ExecStart = "${prune}";
    };
  };
  systemd.user.timers.flakelab-prune = {
    Unit.Description = "flakelab: prune Codex releases and tool caches (${cfg.pruneSchedule})";
    Timer = {
      OnCalendar = cfg.pruneSchedule;
      # A box that was off at the slot catches up at its next start.
      Persistent = true;
      RandomizedDelaySec = "1h";
    };
    Install.WantedBy = [ "timers.target" ];
  };
}
