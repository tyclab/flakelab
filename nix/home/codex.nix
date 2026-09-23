# Codex CLI: official installer into ~/.local/bin.
# An activation entry added here must also be named in health.nix's
# flakelabHealthCheck entryAfter list, or that check stops running last.
{
  lib,
  pkgs,
  flakelab,
  ...
}:
let
  inherit (flakelab) installCodex flakelabDefer;
in
{
  # The nixpkgs build lags upstream. `codex update` runs this same installer, so one
  # run per switch installs the first time and updates after; a release already in
  # ~/.codex/packages is not downloaded again. The binary is static: no nix-ld.
  home.activation.installCodexCli = lib.hm.dag.entryAfter [ "writeBoundary" "flakelabWarnReset" ] (
    lib.optionalString installCodex ''
      # ~/.local/bin on PATH, or the installer appends a PATH block to ~/.zshrc, a
      # store link, and aborts.
      export PATH="${
        lib.makeBinPath [
          pkgs.curl
          pkgs.bash
          pkgs.coreutils
          pkgs.findutils
          pkgs.gnutar
          pkgs.gzip
          pkgs.gawk
          pkgs.gnused
          pkgs.gnugrep
        ]
      }:$HOME/.local/bin:$PATH"
      export SSL_CERT_FILE="${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
      if [ -x "$HOME/.local/bin/codex" ]; then
        _codexMiss="Codex CLI not updated (offline?); it stays on its installed version."
      else
        _codexMiss="Codex CLI not installed: its installer could not be fetched or run (offline?). Retry: flakelab update, or curl -fsSL https://chatgpt.com/codex/install.sh | sh"
      fi
      # pipefail: a failed fetch otherwise pipes an empty script into sh, which exits 0.
      # CODEX_NON_INTERACTIVE: no "Start Codex now?" prompt.
      $DRY_RUN_CMD ${pkgs.bash}/bin/bash -o pipefail -c 'curl -fsSL https://chatgpt.com/codex/install.sh | CODEX_NON_INTERACTIVE=1 sh' || \
        ${flakelabDefer} "$_codexMiss"
    ''
  );
}
