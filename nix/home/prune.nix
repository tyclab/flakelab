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
    # A uv or pre-commit prune that fails no longer passes for done: the run goes on with
    # the rest and the unit ends failed, so `flakelab doctor` and
    # `systemctl --user --failed` show it.
    failed=0
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
    # uv cache prune needs the cache to itself. Two things kept it from running on
    # GamerTyc while the unit still reported success: a `uv run` holds the cache's lock
    # for as long as it lives, so the prune timed out every night from 2026-11-15 to
    # 2026-11-19; and folders a process running as root wrote into the cache cannot be
    # deleted, so it failed from 2026-11-20. A failure names whichever of the two it finds.
    uvCache="$(uv cache dir)"
    if ! uv cache prune; then
      failed=1
      lock="$uvCache/.lock"
      for pid in /proc/[0-9]*; do
        for fd in "$pid"/fd/*; do
          [ "$(readlink "$fd" 2> /dev/null)" = "$lock" ] || continue
          echo "flakelab-prune: the uv cache is held by pid ''${pid#/proc/}: $(tr '\0' ' ' < "$pid/cmdline" 2> /dev/null)" >&2
          break
        done
      done
      stuck="$(find "$uvCache" -xdev -type d ! -writable -print 2> /dev/null)"
      if [ -n "$stuck" ]; then
        first="$(printf '%s\n' "$stuck" | head -n 1)"
        echo "flakelab-prune: $(printf '%s\n' "$stuck" | wc -l) folder(s) in the uv cache are not writable for $(id -un), the first $first (owner $(stat -c %U "$first")); sudo chown -R $(id -un) $uvCache gives them back" >&2
      fi
    fi
    if ! pre-commit gc; then
      failed=1
      echo "flakelab-prune: pre-commit gc failed" >&2
    fi
    exit "$failed"
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
