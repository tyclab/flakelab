# Activation reporting: the log reset every run starts with, and the health
# check that must be the LAST activation entry.
#
# flakelabHealthCheck's entryAfter list below is the contract every other module
# is held to: an activation entry added anywhere in nix/home/ must be appended
# there (or declare `lib.hm.dag.entryBefore [ "flakelabHealthCheck" ]`), or the
# check runs before it and reports on work that has not happened yet.
{
  lib,
  pkgs,
  osConfig,
  flakelab,
  ...
}:
let
  cfg = osConfig.flakelab;
  inherit (flakelab)
    stateDir
    warnLog
    deferredLog
    sshAgentPreamble
    installKiro
    installClaude
    kiroPluginRepo
    kiroPlugin
    ;

  # Marker honoured alongside FLAKELAB_SKIP_HEALTHCHECK=1: activation runs from a
  # systemd unit, so a variable exported in the operator's shell never reaches it.
  healthCheckSkipMarker = "${stateDir}/skip-healthcheck";
in
{
  # Truncate the report collectors at the very start of every activation run.
  # Without this a failure from an earlier rebuild lives forever in the log and
  # the health check below keeps failing on state that is already fixed.
  home.activation.flakelabWarnReset = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    export PATH="${lib.makeBinPath [ pkgs.coreutils ]}:$PATH"
    mkdir -p "${stateDir}"
    rm -f "${warnLog}" "${deferredLog}"
  '';

  # ── Post-activation health check (must be the LAST activation entry) ───────
  # The installers (kiro.nix, claude.nix) are warn-not-fail by design, which is
  # why a rebuild can report success on a distro with no kiro-cli, no plugins and
  # no repos. This turns that silence back into a failed activation: it fails on
  # anything flakelab-warn recorded, plus the post-conditions that must hold
  # unattended.
  # Operator-only state (an agent holding a key, a browser login) is deliberately
  # NOT asserted — it needs a TTY, so it lives in `flakelab doctor` instead.
  home.activation.flakelabHealthCheck =
    lib.hm.dag.entryAfter
      [
        "writeBoundary"
        "flakelabWarnReset"
        "installKiroCli"
        "kiroInstallGlobal"
        "kiroMcpMerge"
        "installClaudeCode"
        "installClaudePlugins"
        "pruneClaudeMcpPlugins"
        "claudeDisableAttribution"
        "claudeStatusline"
        "claudePlaywrightEnv"
        "claudeWhatsappEnv"
        "claudeMcpMerge"
        "claudePermissions"
        "claudeMd"
        "pinNpm"
        "bwConfigServer"
      ]
      ''
        export PATH="${
          lib.makeBinPath [
            pkgs.jq
            pkgs.coreutils
            pkgs.openssh
            pkgs.nodejs_24
          ]
        }:$PATH"

        # Activation runs from the home-manager-${cfg.username}.service unit, so a
        # variable exported in the operator's shell never reaches it — hence the
        # marker file as well.
        if [ "''${FLAKELAB_SKIP_HEALTHCHECK:-}" = "1" ] || [ -e "${healthCheckSkipMarker}" ]; then
          echo "flakelab health check: SKIPPED (FLAKELAB_SKIP_HEALTHCHECK / skip-healthcheck marker)."
        else
          ${sshAgentPreamble}
          echo "flakelab health check:"
          _hcFail=0
          _hcOk() { printf '  [ OK ] %s\n' "$1"; }
          # $((x + 1)) rather than ((x++)): activation runs under `set -e`, where a
          # post-increment whose value is 0 aborts the whole script.
          _hcBad() {
            printf '  [FAIL] %s\n' "$1" >&2
            _hcFail=$((_hcFail + 1))
          }
          _hcSkip() { printf '  [DEFER] %s\n' "$1" >&2; }
          # A post-condition that an already-reported deferral explains is not a
          # defect. Without this the first rebuild on a fresh distro (no agent key
          # yet) and any offline rebuild would BOTH fail activation, which is
          # strictly worse than the silent success this replaces.
          _hcDeferredMentions() { [ -s "${deferredLog}" ] && grep -qi -- "$1" "${deferredLog}"; }
          _hcBadUnlessDeferred() {
            if _hcDeferredMentions "$2"; then
              _hcSkip "$1 (deferred, see above)"
            else
              _hcBad "$1"
            fi
          }

          if [ -s "${warnLog}" ]; then
            _hcBad "activation step(s) reported failures:"
            while IFS= read -r _hcLine; do
              printf '         %s\n' "$_hcLine" >&2
            done < "${warnLog}"
          else
            _hcOk "no activation step reported a failure"
          fi

          if [ -s "${deferredLog}" ]; then
            while IFS= read -r _hcLine; do
              _hcSkip "$_hcLine"
            done < "${deferredLog}"
          fi

          if [ "$_sshReady" = 1 ]; then
            _hcOk "ssh-agent reachable with a loaded key during activation"
          else
            _hcSkip "no ssh-agent key during activation — SSH-dependent steps are deferred, not failed"
          fi

          ${lib.optionalString installKiro ''
            if [ -x "$HOME/.local/bin/kiro-cli" ]; then
              _hcOk "kiro-cli installed (~/.local/bin/kiro-cli)"
            else
              _hcBadUnlessDeferred "kiro-cli missing or not executable: ~/.local/bin/kiro-cli" "kiro-cli"
            fi
          ''}
          ${lib.optionalString (installKiro && kiroPluginRepo != null) ''
            if [ -d "${kiroPlugin}/.git" ]; then
              _hcOk "kiro-plugin checkout present (${kiroPlugin})"
            else
              _hcBadUnlessDeferred "kiro-plugin checkout missing: ${kiroPlugin}/.git" "kiro-plugin not cloned"
            fi
          ''}
          _hcMcp="$HOME/.kiro/settings/mcp.json"
          if [ -f "$_hcMcp" ] && jq -e . "$_hcMcp" >/dev/null 2>&1; then
            _hcOk "mcp.json valid JSON, $(jq -r '(.mcpServers // {}) | length' "$_hcMcp") server(s)"
          else
            _hcBad "~/.kiro/settings/mcp.json missing or not valid JSON"
          fi

          ${lib.optionalString installClaude ''
            if [ -x "$HOME/.local/bin/claude" ]; then
              _hcOk "claude installed (~/.local/bin/claude)"
            else
              _hcBadUnlessDeferred "claude missing or not executable: ~/.local/bin/claude" "Claude Code not installed"
            fi
          ''}

          # A sops-enrolled box renders the env into the /run ramfs and zsh
          # prefers that source; its presence is worth a line. The legacy-file
          # check below still runs while both exist — CR damage only ever lives
          # in the hand-written file, never in a sops render.
          if [ -r /run/secrets/tyc-env ]; then
            _hcOk "sops secrets env present (/run/secrets/tyc-env)"
          fi

          # Only the shape is inspected, never a value: a CR trapped inside a
          # single-quoted value makes GITLAB_TOKEN one byte too long and breaks
          # every GitLab API call with `invalid header field value`.
          _hcSecrets="$HOME/.config/tyc/secrets.env"
          if [ ! -f "$_hcSecrets" ]; then
            _hcOk "secrets.env absent (nothing to validate)"
          elif [ "$(wc -c < "$_hcSecrets")" = "$(tr -d '\r' < "$_hcSecrets" | wc -c)" ]; then
            _hcOk "secrets.env present and free of carriage returns"
          else
            _hcBad "secrets.env has CRLF line endings; fix: tr -d '\r' < ~/.config/tyc/secrets.env > /tmp/s && mv /tmp/s ~/.config/tyc/secrets.env"
          fi

          # glab refuses to start on any config file it reads at a mode other than 600.
          _hcGlabSeen=0
          _hcGlabBad=0
          for _hcYml in "$HOME"/.config/glab-cli/*.yml; do
            [ -f "$_hcYml" ] || continue
            _hcGlabSeen=$((_hcGlabSeen + 1))
            _hcMode="$(stat -c '%a' "$_hcYml")"
            if [ "$_hcMode" != "600" ]; then
              _hcGlabBad=$((_hcGlabBad + 1))
              _hcBad "$_hcYml is mode $_hcMode, must be 600 (glab refuses to run)"
            fi
          done
          if [ "$_hcGlabSeen" -eq 0 ]; then
            # Not a pass: glab has simply never been configured here, and
            # `flakelab clone` fails on the missing token/config either way.
            _hcSkip "no ~/.config/glab-cli/*.yml yet — glab is unconfigured (flakelab doctor reports this)"
          elif [ "$_hcGlabBad" -eq 0 ]; then
            _hcOk "glab-cli config permissions ($_hcGlabSeen file(s) checked)"
          fi

          # ~/.npmrc points npm's prefix at a writable dir; without it the prefix is
          # the read-only nodejs store path and every `npm i -g` dies on ENOENT.
          _hcPrefix="$(npm config get prefix 2>/dev/null || true)"
          case "$_hcPrefix" in
            /nix/store/*)
              _hcBad "npm prefix is the read-only store path $_hcPrefix; ~/.npmrc did not take effect"
              ;;
            "")
              _hcBad "could not read 'npm config get prefix'"
              ;;
            *)
              _hcOk "npm prefix writable target ($_hcPrefix)"
              ;;
          esac

          if [ "$_hcFail" -gt 0 ]; then
            echo "flakelab health check FAILED: $_hcFail problem(s)." >&2
            echo "  Diagnose everything, including the interactive checks activation cannot make:" >&2
            echo "    flakelab doctor" >&2
            echo "  Full output of this run: journalctl -u home-manager-${cfg.username}.service -e" >&2
            echo "  To activate anyway: touch ${healthCheckSkipMarker}" >&2
            echo "    (or FLAKELAB_SKIP_HEALTHCHECK=1 when running the activation script directly)" >&2
            exit 1
          fi
          if [ -s "${deferredLog}" ]; then
            echo "flakelab health check passed, with deferred work above — finish it with: flakelab doctor" >&2
          else
            echo "flakelab health check passed."
          fi
        fi
      '';
}
