# Claude Code: installer, plugins/marketplaces, settings.json policy, ~/.claude.json
# servers, and the managed block in ~/.claude/CLAUDE.md.
# An activation entry added here must also be named in health.nix's
# flakelabHealthCheck entryAfter list, or that check stops running last.
{
  lib,
  pkgs,
  osConfig,
  flakelab,
  flakelabMcp,
  ...
}:
let
  cfg = osConfig.flakelab;
  inherit (flakelab)
    installClaude
    isWsl
    sshAgentPreamble
    sshDefer
    flakelabWarn
    flakelabDefer
    cloneKeyResolve
    sshKeys
    ;
  inherit (flakelabMcp)
    grafanaServer
    whatsappServer
    whatsappMcpDir
    windowsChromePath
    ;

  inherit (cfg) claudeAutoUpdatesChannel claudeAutoMode claudePlugins;

  claudeOutputStyleJq = lib.optionalString (cfg.claudeOutputStyle != null) ''
    | .outputStyle = ${builtins.toJSON cfg.claudeOutputStyle}
  '';

  # A file, not an inline literal: the prose carries apostrophes.
  claudeAutoModeFile = pkgs.writeText "claude-automode.json" (builtins.toJSON claudeAutoMode);

  # permissions.deny is the one layer neither the classifier nor the operator can
  # clear, so it holds only what no workflow types: --mirror deletes every remote
  # ref the local lacks, on refs branch protection does not cover. Force-push is
  # refused by the forge on main for every clone and token. See AUTO-MODE.md.
  claudeDeny = [
    "Bash(git push --mirror*)"
    "Bash(git -C * push --mirror*)"
  ];

  # defaultMode and skipAutoPermissionPrompt travel together: Claude clears the
  # consent flag whenever the mode is not auto. The four vars are deleted, not set
  # to "0": they gate the feature-flag evaluation Remote Control needs.
  claudeAgentDefaultsJq = lib.optionalString cfg.claudeAgentDefaults ''
    | .permissions.defaultMode = "auto"
    | .skipAutoPermissionPrompt = true
    | .remoteControlAtStartup = true
    | .env |= del(
        .DISABLE_TELEMETRY,
        .DO_NOT_TRACK,
        .CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC,
        .DISABLE_GROWTHBOOK
      )
  '';

  # SessionEnd starts the state-sync oneshot so a closed session reaches the state
  # root at once. Owned by its unit name: a box without the sync drops the hook
  # again, and a hand-added SessionEnd hook is left alone.
  stateSyncScheduled = cfg.stateRoot != null && cfg.stateSyncInterval != null;
  claudeStatePushCmd = "systemctl --user start --no-block flakelab-state-sync.service >/dev/null 2>&1 || true";
  claudeStatePushArg = lib.optionalString stateSyncScheduled "--arg push ${lib.escapeShellArg claudeStatePushCmd}";
  claudeStatePushJq = ''
    | .hooks = ((.hooks // {})
        | .SessionEnd = (((.SessionEnd // [])
            | map(select((.hooks // []) | any((.command // "") | contains("flakelab-state-sync.service")) | not)))
            + ${
              if stateSyncScheduled then ''[{hooks: [{type: "command", command: $push}]}]'' else "[]"
            })
        | if .SessionEnd == [] then del(.SessionEnd) else . end)
    | if .hooks == {} then del(.hooks) else . end
  '';

  # Written only when absent, so a local override survives; the sort -V glob
  # resolves the newest cached plugin version at statusline time.
  statuslineMarketplace = marketplaceOf "statusbar";
  claudeStatuslineCmd = ''bash "$(ls -d ~/.claude/plugins/cache/${statuslineMarketplace}/statusbar/*/ | sort -V | tail -1)statusline-command.sh"'';
  claudeStatuslineArg = lib.optionalString (
    statuslineMarketplace != null
  ) "--arg statusline ${lib.escapeShellArg claudeStatuslineCmd}";
  claudeStatuslineJq = lib.optionalString (statuslineMarketplace != null) ''
    | .statusLine //= {type: "command", command: $statusline}
  '';

  # Without these the Playwright server launches a local chrome instead of
  # attaching to Windows Chrome.
  claudePlaywrightJq = lib.optionalString (isWsl && lib.elem "mcp-playwright" claudePlugins) ''
    | .env += ${
      builtins.toJSON {
        PLAYWRIGHT_MCP_EXECUTABLE_PATH = windowsChromePath;
        PLAYWRIGHT_MCP_EXTENSION = "true";
        PLAYWRIGHT_MCP_BROWSER = "chrome";
      }
    }
  '';

  # Non-secret halves only: the API key stays in secrets.env.
  claudeWhatsappJq =
    lib.optionalString
      (
        lib.elem "mcp-whatsapp" claudePlugins
        && cfg.sessionVariables ? WHATSAPP_BRIDGE_HOST
        && whatsappMcpDir != null
      )
      ''
        | .env += ${
          builtins.toJSON {
            WHATSAPP_MCP_DIR = whatsappMcpDir;
            WHATSAPP_BRIDGE_HOST = cfg.sessionVariables.WHATSAPP_BRIDGE_HOST;
            WHATSAPP_MCP_TOOLSETS = "core,send,media";
          }
        }
      '';

  # Newline-terminated, or the END marker lands on the last line of the extra text.
  claudeMdExtraFile = pkgs.writeText "claude-md-extra.md" (
    lib.removeSuffix "\n" cfg.claudeMdExtra + "\n"
  );
  claudeMdExtraCat = lib.optionalString (
    cfg.claudeMdExtra != ""
  ) "printf '\\n'; cat ${claudeMdExtraFile}";

  claudeMarketplaces = cfg.claudePluginMarketplaces;
  firstMarketplace =
    if claudeMarketplaces == [ ] then null else (builtins.head claudeMarketplaces).name;
  # `plugin install` requires `plugin@marketplace`; bare names are qualified here.
  qualifiedClaudePlugins = map (
    p: if lib.hasInfix "@" p || firstMarketplace == null then p else "${p}@${firstMarketplace}"
  ) claudePlugins;
  # The marketplace a plugin is installed from; null when the plugin is not enabled.
  marketplaceOf =
    p:
    let
      match = lib.findFirst (q: q == p || lib.hasPrefix "${p}@" q) null claudePlugins;
    in
    if match == null then
      null
    else if lib.hasInfix "@" match then
      lib.last (lib.splitString "@" match)
    else
      firstMarketplace;

  # Skipped where a marketplace plugin already provides the server: two whatsapp
  # servers that can send as the user is worse than one.
  claudeMcpServers = builtins.removeAttrs (
    lib.optionalAttrs (cfg.sessionVariables ? GRAFANA_URL && marketplaceOf "mcp-grafana" == null) {
      grafana = grafanaServer // {
        type = "stdio";
      };
    }
    //
      lib.optionalAttrs
        (
          cfg.sessionVariables ? WHATSAPP_BRIDGE_HOST
          && whatsappMcpDir != null
          && marketplaceOf "mcp-whatsapp" == null
        )
        {
          whatsapp = whatsappServer // {
            type = "stdio";
          };
        }
    // cfg.claudeMcpServers
  ) cfg.claudeMcpDisabledServers;

  jqPath = ''export PATH="${
    lib.makeBinPath [
      pkgs.jq
      pkgs.coreutils
    ]
  }:$PATH"'';
in
{
  # The nixpkgs build lags what this environment needs, so bootstrap the official
  # installer once; its auto-updater keeps it current, and nix-ld runs the binary.
  home.activation.installClaudeCode = lib.hm.dag.entryAfter [ "writeBoundary" "flakelabWarnReset" ] (
    lib.optionalString installClaude ''
      if [ ! -x "$HOME/.local/bin/claude" ]; then
        export PATH="${
          lib.makeBinPath [
            pkgs.curl
            pkgs.bash
            pkgs.coreutils
          ]
        }:$PATH"
        export SSL_CERT_FILE="${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
        # pipefail: a failed fetch otherwise pipes an empty script into bash, which exits 0.
        $DRY_RUN_CMD ${pkgs.bash}/bin/bash -o pipefail -c 'curl -fsSL https://claude.ai/install.sh | bash' || \
          ${flakelabDefer} "Claude Code not installed (offline?). Retry: flakelab update"
      fi
    ''
  );

  # Adds each marketplace over SSH with the seeded key and installs claudePlugins
  # from it; failures warn rather than block.
  home.activation.installClaudePlugins =
    lib.hm.dag.entryAfter [ "writeBoundary" "flakelabWarnReset" "installClaudeCode" ]
      (
        lib.optionalString (installClaude && claudeMarketplaces != [ ]) ''
          _claude="$HOME/.local/bin/claude"
          ${cloneKeyResolve}
          if [ -x "$_claude" ] && [ -n "$_cloneKey" ]; then
            export PATH="${
              lib.makeBinPath [
                pkgs.git
                pkgs.openssh
                pkgs.coreutils
              ]
            }:$PATH"
            export GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=accept-new -i $_cloneKey"
            ${sshAgentPreamble}
          ${lib.concatMapStringsSep "\n" (m: ''
            if ! "$_claude" plugin marketplace list 2>/dev/null | grep -q ${lib.escapeShellArg m.name}; then
              "$_claude" plugin marketplace add ${lib.escapeShellArg m.url} || \
                ${
                  if lib.hasPrefix "git@" m.url then
                    sshDefer "claude marketplace ${m.name} not added (no unlocked agent key, or host unreachable). Retry: flakelab update"
                  else
                    ''${flakelabDefer} "claude marketplace ${m.name} not added (offline?). Retry: flakelab update"''
                }
            else
              # A registered marketplace never re-fetches itself.
              "$_claude" plugin marketplace update ${lib.escapeShellArg m.name} >/dev/null 2>&1 || \
                ${flakelabDefer} "claude marketplace ${m.name} not updated. Retry: flakelab update"
            fi'') claudeMarketplaces}
            for _p in ${lib.concatStringsSep " " qualifiedClaudePlugins}; do
              if "$_claude" plugin install "$_p" >/dev/null 2>&1; then
                # install is a no-op on an installed plugin; only update moves it.
                "$_claude" plugin update "$_p" >/dev/null 2>&1 || \
                  ${flakelabWarn} "claude plugin $_p not updated."
                # Installed is not loaded; enable exits 1 when already enabled.
                if ! _enabled="$("$_claude" plugin enable "$_p" 2>&1)"; then
                  case "$_enabled" in
                    *"already enabled"*) ;;
                    *) ${flakelabWarn} "claude plugin $_p not enabled." ;;
                  esac
                fi
              else
                ${flakelabDefer} "claude plugin $_p not installed: marketplace not fetched. Retry: flakelab update"
              fi
            done
          elif [ -x "$_claude" ]; then
            ${flakelabDefer} "claude marketplaces not installed: none of ~/.ssh/{${lib.concatStringsSep "," sshKeys}} exists yet. Retry: flakelab update"
          fi
        ''
      );

  # Uninstalls an mcp-* plugin from our marketplaces that claudePlugins no longer
  # names; </dev/null bounds any interactive prompt.
  home.activation.pruneClaudeMcpPlugins =
    lib.hm.dag.entryAfter [ "writeBoundary" "flakelabWarnReset" "installClaudePlugins" ]
      (
        lib.optionalString (installClaude && claudeMarketplaces != [ ]) ''
          ${jqPath}
          _claude="$HOME/.local/bin/claude"
          _ip="$HOME/.claude/plugins/installed_plugins.json"
          if [ -x "$_claude" ] && [ -f "$_ip" ]; then
            for _m in ${lib.concatMapStringsSep " " (m: lib.escapeShellArg m.name) claudeMarketplaces}; do
              # Assigned separately: a corrupt registry must not read as "nothing to prune".
              if ! _keys="$(jq -r --arg m "@$_m" '.plugins // {} | keys[] | select(endswith($m)) | select(startswith("mcp-"))' "$_ip" 2>/dev/null)"; then
                ${flakelabWarn} "could not read $_ip; skipping the MCP plugin prune."
                continue
              fi
              for _key in $_keys; do
                case " ${lib.concatStringsSep " " qualifiedClaudePlugins} " in
                  *" $_key "*) continue ;;
                esac
                "$_claude" plugin uninstall "$_key" </dev/null >/dev/null 2>&1 || \
                  ${flakelabWarn} "could not uninstall opted-out plugin $_key."
              done
            done
          fi
        ''
      );

  # The settings.json policy in one pass: attribution off, feedback and error
  # reporting off, installMethod, the update channel, autoMode and the deny floor
  # asserted whole, then the opt-in bundle, statusline and plugin env.
  # permissions.allow/ask are not here: the marketplace clone they come from is
  # runtime data, so nix-update asserts them after every switch.
  home.activation.claudeSettings =
    lib.hm.dag.entryAfter [ "writeBoundary" "flakelabWarnReset" "installClaudeCode" ]
      (
        lib.optionalString installClaude ''
          ${jqPath}
          _settings="$HOME/.claude/settings.json"
          _attrs='{"commit":"","pr":"","sessionUrl":false}'
          _env='{"CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY":"1","DISABLE_FEEDBACK_COMMAND":"1","DISABLE_ERROR_REPORTING":"1"}'
          _deny=${lib.escapeShellArg (builtins.toJSON claudeDeny)}
          mkdir -p "$HOME/.claude"
          # `-s`, not `-f`, so a zero-byte settings.json heals.
          [ -s "$_settings" ] || printf '{}' > "$_settings"
          jq --argjson a "$_attrs" --argjson e "$_env" --argjson d "$_deny" --slurpfile am ${claudeAutoModeFile} ${claudeStatePushArg} ${claudeStatuslineArg} '
            .attribution = ($a + (.attribution // {}))
            | .feedbackSurveyRate = 0
            | .env += $e
            | .installMethod = "native"
            | .autoUpdatesChannel = "${claudeAutoUpdatesChannel}"
            | .autoMode = $am[0]
            | .permissions.deny = $d
            ${claudeOutputStyleJq}
            ${claudeAgentDefaultsJq}
            ${claudeStatePushJq}
            ${claudeStatuslineJq}
            ${claudePlaywrightJq}
            ${claudeWhatsappJq}
          ' "$_settings" > "$_settings.tmp" && mv "$_settings.tmp" "$_settings" || {
            rm -f "$_settings.tmp"
            ${flakelabWarn} "could not update $_settings."
          }
          # env carries MCP credentials, and the merge replaces the inode.
          chmod 600 "$_settings"
        ''
      );

  # `claude mcp add` refuses an existing name, so converge on the file: declared
  # servers are reasserted, hand-added ones survive. `+`, not `*`, or an arg
  # dropped from a declaration would linger.
  home.activation.claudeMcpMerge =
    lib.hm.dag.entryAfter [ "writeBoundary" "flakelabWarnReset" "installClaudeCode" ]
      (
        lib.optionalString
          (installClaude && (claudeMcpServers != { } || cfg.claudeMcpDisabledServers != [ ]))
          ''
            ${jqPath}
            _claudeJson="$HOME/.claude.json"
            _ours=${lib.escapeShellArg (builtins.toJSON claudeMcpServers)}
            _disabled=${lib.escapeShellArg (builtins.toJSON cfg.claudeMcpDisabledServers)}
            [ -s "$_claudeJson" ] || echo '{}' > "$_claudeJson"
            _tmp="$(mktemp)"
            if jq --argjson ours "$_ours" --argjson disabled "$_disabled" '
                 .mcpServers = ((.mcpServers // {}) + $ours)
                 | reduce $disabled[] as $name (.; del(.mcpServers[$name]))' \
                 "$_claudeJson" > "$_tmp" 2>/dev/null && [ -s "$_tmp" ]; then
              # 600: the same file carries Claude's account and OAuth state.
              $DRY_RUN_CMD install -m600 "$_tmp" "$_claudeJson"
            else
              ${flakelabWarn} "could not merge Claude MCP servers into $_claudeJson."
            fi
            rm -f "$_tmp"
          ''
      );

  # Nothing here pins Claude or its marketplaces, so the two switches that would
  # stop their self-updates are asserted: the native installer writes
  # autoUpdates=false to fence off the legacy npm updater, and every marketplace
  # but Anthropic's defaults to no auto-update. An absent file stays absent.
  home.activation.claudeAutoUpdates =
    lib.hm.dag.entryAfter
      [
        "writeBoundary"
        "flakelabWarnReset"
        "installClaudeCode"
        "installClaudePlugins"
        "claudeMcpMerge"
      ]
      (
        lib.optionalString installClaude ''
          ${jqPath}
          _tmp="$(mktemp)"
          _claudeJson="$HOME/.claude.json"
          if [ -s "$_claudeJson" ]; then
            if jq '.autoUpdates = true' "$_claudeJson" > "$_tmp" 2>/dev/null && [ -s "$_tmp" ]; then
              $DRY_RUN_CMD install -m600 "$_tmp" "$_claudeJson"
            else
              ${flakelabWarn} "could not enable Claude's auto-updater in $_claudeJson."
            fi
          fi
          ${lib.optionalString (claudeMarketplaces != [ ]) ''
            _known="$HOME/.claude/plugins/known_marketplaces.json"
            if [ -s "$_known" ]; then
              if jq --argjson names ${
                lib.escapeShellArg (builtins.toJSON (map (m: m.name) claudeMarketplaces))
              } \
                   'reduce $names[] as $n (.; if has($n) then .[$n].autoUpdate = true else . end)' \
                   "$_known" > "$_tmp" 2>/dev/null && [ -s "$_tmp" ]; then
                $DRY_RUN_CMD install -m644 "$_tmp" "$_known"
              else
                ${flakelabWarn} "could not enable auto-update for the Claude marketplaces in $_known."
              fi
            fi
          ''}
          rm -f "$_tmp"
        ''
      );

  # A marker block, not a home.file: Claude appends to this file itself, and
  # anything outside the markers survives. Rewritten every activation.
  home.activation.claudeMd =
    lib.hm.dag.entryAfter [ "writeBoundary" "flakelabWarnReset" "claudeSettings" ]
      (
        lib.optionalString installClaude ''
          export PATH="${
            lib.makeBinPath [
              pkgs.gawk
              pkgs.coreutils
            ]
          }:$PATH"
          _md="$HOME/.claude/CLAUDE.md"
          mkdir -p "$HOME/.claude"
          touch "$_md"
          _tmp="$(mktemp)"
          awk '
            index($0, "<!-- BEGIN managed by flakelab -->") == 1 { skip = 1 }
            skip != 1 { print }
            index($0, "<!-- END managed by flakelab -->") == 1 { skip = 0 }
          ' "$_md" > "$_tmp"
          {
            cat "$_tmp"
            echo '<!-- BEGIN managed by flakelab -->'
            cat ${../../files/config/claude/CLAUDE.md}
            printf '\n'
            cat ${../../files/config/claude/target-${cfg.target}.md}
            ${claudeMdExtraCat}
            echo '<!-- END managed by flakelab -->'
          } > "$_tmp.new" && $DRY_RUN_CMD install -m644 "$_tmp.new" "$_md" || \
            ${flakelabWarn} "could not refresh the managed block in $_md."
          rm -f "$_tmp" "$_tmp.new"
        ''
      );
}
