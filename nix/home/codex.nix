# Codex CLI: official installer into ~/.local/bin, and the managed block in
# ~/.codex/AGENTS.md (the same rules ~/.claude/CLAUDE.md carries).
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
  # nixpkgs lags upstream; `codex update` runs this same installer, so it installs once and updates after. Static: no nix-ld.
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
      _codexUrl=https://chatgpt.com/codex/install.sh
      if [ -x "$HOME/.local/bin/codex" ]; then
        _codexMiss="Codex CLI not updated"
        _codexThen="; it stays on its installed version."
      else
        _codexMiss="Codex CLI not installed"
        _codexThen=". Retry: flakelab update, or curl -fsSL $_codexUrl | sh"
      fi
      # Fetched to a file, not piped: a failed fetch never reaches sh, and curl's
      # own error (a 404, no DNS) goes into the deferral.
      _codexSh="$(mktemp)"
      if ! _codexErr="$($DRY_RUN_CMD curl -fsSL -o "$_codexSh" "$_codexUrl" 2>&1)"; then
        ${flakelabDefer} "$_codexMiss: ''${_codexErr:-its installer could not be fetched}$_codexThen"
      # CODEX_NON_INTERACTIVE: no "Start Codex now?" prompt.
      elif ! $DRY_RUN_CMD env CODEX_NON_INTERACTIVE=1 sh "$_codexSh"; then
        ${flakelabDefer} "$_codexMiss: its installer failed$_codexThen"
      fi
      rm -f "$_codexSh"
    ''
  );

  # Codex reads its user-level instructions from $CODEX_HOME/AGENTS.md only, never
  # ~/.claude/CLAUDE.md, so without this block it runs on a different rule set.
  home.activation.codexAgentsMd = lib.hm.dag.entryAfter [ "writeBoundary" "flakelabWarnReset" ] (
    lib.optionalString installCodex (
      flakelab.writeManagedBlock ''"''${CODEX_HOME:-$HOME/.codex}/AGENTS.md"'' flakelab.agentInstructions.codex
    )
  );
}
