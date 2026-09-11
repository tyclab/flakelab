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

  # The only control over what the unpinned self-updater lands on every box.
  inherit (cfg) claudeAutoUpdatesChannel;

  # Asserted only when the overlay names one, so an unset option leaves the key alone.
  claudeOutputStyleJq = lib.optionalString (cfg.claudeOutputStyle != null) ''
    | .outputStyle = ${builtins.toJSON cfg.claudeOutputStyle}
  '';

  # Written unconditionally: the rules only narrow what a session may do, so they
  # cost nothing until auto mode is on. User scope is the only scope Claude reads
  # them from, so a provisioner is the only reproducible place for them.
  inherit (cfg) claudeAutoMode;

  # A file, not an inline literal: the prose carries apostrophes, which would
  # terminate the shell quote.
  claudeAutoModeFile = pkgs.writeText "claude-automode.json" (builtins.toJSON claudeAutoMode);

  # permissions.deny is the one layer neither the classifier nor the operator can
  # clear — precedence 3, short-circuits before auto mode. The invariant above
  # claudeAutoMode therefore binds hardest here: destructive-but-legitimate work
  # belongs in soft_deny. Force-push is not in this floor because the forge already
  # refuses it on main (allow_force_pushes false, enforce_admins on) for every
  # clone and every token, which a client-side glob cannot do. See AUTO-MODE.md.
  #
  # Kept: --mirror deletes every remote ref the local does not have, on refs branch
  # protection does not cover. Globs match raw command text across `&&` and `|`,
  # quoted bodies included, so `--mirror` is the whole reason a rule can be this
  # blunt and still be safe — no legitimate workflow here types it.
  claudeDeny = [
    "Bash(git push --mirror*)"
    "Bash(git -C * push --mirror*)"
  ];

  # Rules this floor used to assert. Subtracted before the union so a box that
  # already merged them converges instead of carrying them forever.
  claudeDenyStale = [
    "Bash(git push --force*)"
    "Bash(git push -f*)"
    "Bash(git push * --force*)"
    "Bash(git push * -f*)"
    "Bash(git push * +*)"
    "Bash(git -C * push --force*)"
    "Bash(git -C * push -f*)"
    "Bash(git -C * push * --force*)"
    "Bash(git -C * push * -f*)"
    "Bash(git -C * push * +*)"
    "Bash(git push * :*)"
    "Bash(git push --delete*)"
  ];

  # The opt-in agent-box bundle, as a jq fragment appended to the seeded merge below
  # so it covers the create case too. defaultMode and skipAutoPermissionPrompt must
  # travel together: Claude clears the consent flag whenever the mode is not auto.
  # The four vars are deleted, not set to "0": they gate the feature-flag evaluation
  # Remote Control needs, and two of them are raw truthiness. Of the four, only
  # CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC also stops the self-updater this flake
  # relies on (Claude Code 2.1.267 and 2.1.268).
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

  # A session that closes cleanly is pushed at once instead of waiting out the
  # state-sync timer: SessionEnd starts the timer's own oneshot — `--no-block`, and a
  # start while a run is active joins that run rather than queueing another. Owned by
  # its unit name, so a box whose sync is switched off drops the hook again and a
  # hand-added SessionEnd hook is never touched. A crash fires no hook; the timer and
  # the session autosave cover that.
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

  # Newline-terminated whatever the overlay wrote, or the END marker lands on the
  # last line of the appended text and the block stops parsing as one.
  claudeMdExtraFile = pkgs.writeText "claude-md-extra.md" (
    lib.removeSuffix "\n" cfg.claudeMdExtra + "\n"
  );
  claudeMdExtraCat = lib.optionalString (
    cfg.claudeMdExtra != ""
  ) "printf '\\n'; cat ${claudeMdExtraFile}";

  # The singular form stays honoured for an overlay predating the list.
  claudeMarketplaces =
    let
      plural = cfg.claudePluginMarketplaces;
      singular = cfg.claudePluginMarketplace;
    in
    if plural != [ ] then
      plural
    else if singular != null then
      [ singular ]
    else
      [ ];
  inherit (cfg) claudePlugins;
  firstMarketplace =
    if claudeMarketplaces == [ ] then null else (builtins.head claudeMarketplaces).name;
  # `plugin install` requires `plugin@marketplace`; bare names are qualified here.
  qualifiedClaudePlugins = map (
    p: if lib.hasInfix "@" p || firstMarketplace == null then p else "${p}@${firstMarketplace}"
  ) claudePlugins;
  # Locates a plugin's cache dir; null when the plugin is not enabled.
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

  # Claude writes ~/.claude.json itself, so these are merged in by the claudeMcpMerge
  # activation rather than being a home.file. Gated on the same sessionVariables as
  # the Kiro set, and skipped where a marketplace plugin already provides the server
  # - two whatsapp servers, which can send messages as the user, is worse than one.
  claudeMcpServers =
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
    // cfg.claudeMcpServers;
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
        $DRY_RUN_CMD ${pkgs.bash}/bin/bash -c 'curl -fsSL https://claude.ai/install.sh | bash' || \
          ${flakelabDefer} "Claude Code not installed: its installer could not be fetched or run (offline?). Retry: flakelab update, or curl -fsSL https://claude.ai/install.sh | bash"
      fi
    ''
  );

  # Adds each configured marketplace over SSH with the seeded key and installs
  # claudePlugins from it; idempotent, and failures warn rather than block.
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
                    sshDefer "claude marketplace ${m.name} not added. Either activation had no passphrase-unlocked ssh-agent key for its git@ source, or the host was unreachable. Log in interactively, then run: flakelab update"
                  else
                    ''${flakelabDefer} "claude marketplace ${m.name} not added: source unreachable (offline?). Retry: flakelab update"''
                }
            else
              # A registered marketplace never re-fetches itself, and a stale clone
              # quietly pins every plugin to its last fetch.
              "$_claude" plugin marketplace update ${lib.escapeShellArg m.name} >/dev/null 2>&1 || \
                ${flakelabDefer} "claude marketplace ${m.name} not updated (offline, or no agent key); plugin updates resolve against its last fetch. Retry: flakelab update"
            fi'') claudeMarketplaces}
            for _p in ${lib.concatStringsSep " " qualifiedClaudePlugins}; do
              if "$_claude" plugin install "$_p" >/dev/null 2>&1; then
                # install is a no-op on an installed plugin, so only an explicit
                # update moves the MCP server pinned inside it.
                "$_claude" plugin update "$_p" >/dev/null 2>&1 || \
                  ${flakelabWarn} "claude plugin $_p not updated; it stays on its installed version."
                # Installed is not loaded: a plugin reaches a session only when
                # settings.enabledPlugins names it. Unlike install, enable exits 1
                # when the plugin is already enabled, which is the steady state.
                if ! _enabled="$("$_claude" plugin enable "$_p" 2>&1)"; then
                  case "$_enabled" in
                    *"already enabled"*) ;;
                    *) ${flakelabWarn} "claude plugin $_p not enabled; it stays installed but loads nothing into a session." ;;
                  esac
                fi
              else
                ${flakelabDefer} "claude plugin $_p not installed: its marketplace was not fetched (no agent key, or unreachable). Retry: flakelab update"
              fi
            done
          elif [ -x "$_claude" ]; then
            # Claude is there but the key is not: say so, or the operator has no
            # reason to run `flakelab update`.
            ${flakelabDefer} "claude marketplaces and plugins not installed: none of ~/.ssh/{${lib.concatStringsSep "," sshKeys}} exists yet, so the git@ marketplaces could not be fetched. Provisioning seeds a key after this rebuild; flakelab update then completes it."
          fi
        ''
      );

  # Uninstalls an mcp-* plugin from our own marketplaces that claudePlugins no longer
  # names; </dev/null bounds any interactive prompt.
  home.activation.pruneClaudeMcpPlugins =
    lib.hm.dag.entryAfter [ "writeBoundary" "flakelabWarnReset" "installClaudePlugins" ]
      (
        lib.optionalString (installClaude && claudeMarketplaces != [ ]) ''
          export PATH="${
            lib.makeBinPath [
              pkgs.jq
              pkgs.coreutils
            ]
          }:$PATH"
          _claude="$HOME/.local/bin/claude"
          _ip="$HOME/.claude/plugins/installed_plugins.json"
          if [ -x "$_claude" ] && [ -f "$_ip" ]; then
            for _m in ${lib.concatMapStringsSep " " (m: lib.escapeShellArg m.name) claudeMarketplaces}; do
              # Assigned separately, so a corrupt registry aborts the pass instead of
              # looking like "nothing to prune".
              if ! _keys="$(jq -r --arg m "@$_m" '.plugins // {} | keys[] | select(endswith($m)) | select(startswith("mcp-"))' "$_ip" 2>/dev/null)"; then
                ${flakelabWarn} "could not read $_ip; skipping the MCP plugin prune."
                continue
              fi
              for _key in $_keys; do
                case " ${lib.concatStringsSep " " qualifiedClaudePlugins} " in
                  *" $_key "*) continue ;;
                esac
                "$_claude" plugin uninstall "$_key" </dev/null >/dev/null 2>&1 || \
                  ${flakelabWarn} "could not uninstall opted-out plugin $_key; it keeps loading its tools into every session."
              done
            done
          fi
        ''
      );

  # The settings.json policy: empty attribution strings drop the commit trailer and
  # PR footer, feedback and error reporting go off, and installMethod records the
  # installer used above. autoMode is asserted whole - it is policy, and a drifted
  # box blocks unpredictably - while the deny list is only a floor.
  # Everything here is written for every adopter; the opt-in bundle rides along in
  # claudeAgentDefaultsJq.
  home.activation.claudeDisableAttribution =
    lib.hm.dag.entryAfter [ "writeBoundary" "flakelabWarnReset" "installClaudeCode" ]
      (
        lib.optionalString installClaude ''
          export PATH="${
            lib.makeBinPath [
              pkgs.jq
              pkgs.coreutils
            ]
          }:$PATH"
          _settings="$HOME/.claude/settings.json"
          _attrs='{"commit":"","pr":"","sessionUrl":false}'
          _env='{"CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY":"1","DISABLE_FEEDBACK_COMMAND":"1","DISABLE_ERROR_REPORTING":"1"}'
          _deny=${lib.escapeShellArg (builtins.toJSON claudeDeny)}
          _denystale=${lib.escapeShellArg (builtins.toJSON claudeDenyStale)}
          mkdir -p "$HOME/.claude"
          # Seeding with `{}` lets one merge cover the create case; `-s`, not `-f`, so
          # a zero-byte settings.json heals.
          [ -s "$_settings" ] || printf '{}' > "$_settings"
          jq --argjson a "$_attrs" --argjson e "$_env" --argjson d "$_deny" --argjson ds "$_denystale" --slurpfile am ${claudeAutoModeFile} ${claudeStatePushArg} '
            .attribution = ($a + (.attribution // {}))
            | .feedbackSurveyRate = 0
            | .env += $e
            | .installMethod = "native"
            | .autoUpdatesChannel = "${claudeAutoUpdatesChannel}"
            | .autoMode = $am[0]
            | .permissions.deny = (((.permissions.deny // []) - $ds) + $d | unique)
            ${claudeOutputStyleJq}
            ${claudeAgentDefaultsJq}
            ${claudeStatePushJq}
          ' "$_settings" > "$_settings.tmp" && mv "$_settings.tmp" "$_settings" || {
            rm -f "$_settings.tmp"
            ${flakelabWarn} "could not update Claude attribution in $_settings."
          }
          # env carries MCP credentials, and the merge above replaces the inode, so the
          # mode is reasserted every activation.
          chmod 600 "$_settings"
        ''
      );

  # Installing the statusbar plugin only caches the script: settings.json must point
  # statusLine at it. Written only when absent, so a local override survives, and the
  # sort -V glob resolves the newest cached version.
  home.activation.claudeStatusline =
    lib.hm.dag.entryAfter [ "writeBoundary" "flakelabWarnReset" "installClaudePlugins" ]
      (
        lib.optionalString (installClaude && marketplaceOf "statusbar" != null) ''
          export PATH="${
            lib.makeBinPath [
              pkgs.jq
              pkgs.coreutils
            ]
          }:$PATH"
          _settings="$HOME/.claude/settings.json"
          mkdir -p "$HOME/.claude"
          [ -f "$_settings" ] || echo '{}' > "$_settings"
          if ! jq -e '.statusLine' "$_settings" >/dev/null 2>&1; then
            _cmd='bash "$(ls -d ~/.claude/plugins/cache/${marketplaceOf "statusbar"}/statusbar/*/ | sort -V | tail -1)statusline-command.sh"'
            jq --arg cmd "$_cmd" '.statusLine = {type: "command", command: $cmd}' "$_settings" > "$_settings.tmp" \
              && mv "$_settings.tmp" "$_settings" || \
              ${flakelabWarn} "could not set Claude statusline in $_settings."
          fi
        ''
      );

  # The mcp-playwright plugin reads these from settings.json env; without them the
  # server launches a local chrome and fails instead of attaching to Windows Chrome.
  home.activation.claudePlaywrightEnv =
    lib.hm.dag.entryAfter [ "writeBoundary" "flakelabWarnReset" "claudeDisableAttribution" ]
      (
        lib.optionalString (installClaude && isWsl && lib.elem "mcp-playwright" claudePlugins) ''
          export PATH="${
            lib.makeBinPath [
              pkgs.jq
              pkgs.coreutils
            ]
          }:$PATH"
          _settings="$HOME/.claude/settings.json"
          mkdir -p "$HOME/.claude"
          [ -f "$_settings" ] || echo '{}' > "$_settings"
          jq '.env += {
                PLAYWRIGHT_MCP_EXECUTABLE_PATH: "${windowsChromePath}",
                PLAYWRIGHT_MCP_EXTENSION: "true",
                PLAYWRIGHT_MCP_BROWSER: "chrome"
              }' "$_settings" > "$_settings.tmp" && mv "$_settings.tmp" "$_settings" || \
            ${flakelabWarn} "could not set Playwright MCP env in $_settings."
        ''
      );

  # The mcp-whatsapp plugin expands these from settings.json env, and resolves them
  # to empty without them. Non-secret values only: the API key stays in secrets.env.
  home.activation.claudeWhatsappEnv =
    lib.hm.dag.entryAfter [ "writeBoundary" "flakelabWarnReset" "claudeDisableAttribution" ]
      (
        lib.optionalString
          (
            installClaude
            && lib.elem "mcp-whatsapp" claudePlugins
            && cfg.sessionVariables ? WHATSAPP_BRIDGE_HOST
            && whatsappMcpDir != null
          )
          ''
            export PATH="${
              lib.makeBinPath [
                pkgs.jq
                pkgs.coreutils
              ]
            }:$PATH"
            _settings="$HOME/.claude/settings.json"
            mkdir -p "$HOME/.claude"
            [ -f "$_settings" ] || echo '{}' > "$_settings"
            jq --arg dir "${whatsappMcpDir}" \
               --arg host "${cfg.sessionVariables.WHATSAPP_BRIDGE_HOST or ""}" \
               '.env += {WHATSAPP_MCP_DIR: $dir, WHATSAPP_BRIDGE_HOST: $host, WHATSAPP_MCP_TOOLSETS: "core,send,media"}' \
               "$_settings" > "$_settings.tmp" && mv "$_settings.tmp" "$_settings" || \
              ${flakelabWarn} "could not set WhatsApp MCP env in $_settings."
          ''
      );

  # `claude mcp add` refuses an existing name, so converge on the file instead:
  # declared servers are reasserted and hand-added ones survive. `+`, not jq's
  # recursive `*`, or an arg dropped from a declaration would linger forever.
  home.activation.claudeMcpMerge =
    lib.hm.dag.entryAfter [ "writeBoundary" "flakelabWarnReset" "installClaudeCode" ]
      (
        lib.optionalString (installClaude && claudeMcpServers != { }) ''
          export PATH="${
            lib.makeBinPath [
              pkgs.jq
              pkgs.coreutils
            ]
          }:$PATH"
          _claudeJson="$HOME/.claude.json"
          _ours=${lib.escapeShellArg (builtins.toJSON claudeMcpServers)}
          [ -s "$_claudeJson" ] || echo '{}' > "$_claudeJson"
          _tmp="$(mktemp)"
          if jq --argjson ours "$_ours" '.mcpServers = ((.mcpServers // {}) + $ours)' \
               "$_claudeJson" > "$_tmp" 2>/dev/null && [ -s "$_tmp" ]; then
            # 600: the same file carries Claude's account and OAuth state.
            $DRY_RUN_CMD install -m600 "$_tmp" "$_claudeJson"
          else
            ${flakelabWarn} "could not merge Claude MCP servers into $_claudeJson; leaving it intact."
          fi
          rm -f "$_tmp"
        ''
      );

  # Claude, its marketplaces and their plugins update themselves; nothing in this
  # flake pins them, so the two switches that can stop that are asserted. Claude's
  # native installer writes autoUpdates=false into ~/.claude.json to fence off the
  # legacy npm updater; from then on only its autoUpdatesProtectedForNative flag
  # keeps updates running, and true does not depend on that flag. Every marketplace
  # but Anthropic's own defaults to no auto-update, so ours would otherwise move
  # only on `flakelab update`. An absent file is Claude's own default and stays so.
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
          export PATH="${
            lib.makeBinPath [
              pkgs.jq
              pkgs.coreutils
            ]
          }:$PATH"
          _tmp="$(mktemp)"
          _claudeJson="$HOME/.claude.json"
          if [ -s "$_claudeJson" ]; then
            if jq '.autoUpdates = true' "$_claudeJson" > "$_tmp" 2>/dev/null && [ -s "$_tmp" ]; then
              # 600: the same file carries Claude's account and OAuth state.
              $DRY_RUN_CMD install -m600 "$_tmp" "$_claudeJson"
            else
              ${flakelabWarn} "could not enable Claude's auto-updater in $_claudeJson; leaving it intact."
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
                ${flakelabWarn} "could not enable auto-update for the Claude marketplaces in $_known; they refresh only on flakelab update."
              fi
            fi
          ''}
          rm -f "$_tmp"
        ''
      );

  # Merges the marketplace's own recommended-permissions.json into allow, unioned
  # so a hand-added rule is kept. Such a list is only safe behind the auto-mode
  # classifier, which is written on every box that has Claude at all.
  # recommended-ask.json is asserted, not unioned: an ask rule prompts even when
  # the operator's own message names the action, so it is the marketplace's list
  # or nothing — a union could only grow, and the 2026-09-04 list would have sat
  # in permissions.ask on every box after the marketplace withdrew it.
  # Each file is located with `find`, not assumed: a hardcoded path the
  # marketplace does not have would defer forever instead of failing. The ask
  # file is optional — a marketplace without one leaves permissions.ask alone.
  home.activation.claudePermissions =
    lib.hm.dag.entryAfter
      [
        "writeBoundary"
        "flakelabWarnReset"
        "installClaudePlugins"
        "claudeDisableAttribution"
      ]
      (
        lib.optionalString (installClaude && firstMarketplace != null) ''
          export PATH="${
            lib.makeBinPath [
              pkgs.jq
              pkgs.coreutils
              # findutils, not coreutils: without `find` the merge silently stops.
              pkgs.findutils
            ]
          }:$PATH"
          # nix-update replays this same merge after every switch: keep them in sync.
          _settings="$HOME/.claude/settings.json"
          _marketplace="$HOME/.claude/plugins/marketplaces/${firstMarketplace}"
          # Guarded: on a missing directory find exits non-zero, which under the
          # activation script's `set -e` silently aborts the whole activation.
          _recommended=""
          _recommendedask=""
          if [ -d "$_marketplace" ]; then
            _recommended="$(find "$_marketplace" -type f -name recommended-permissions.json 2>/dev/null | head -1 || true)"
            _recommendedask="$(find "$_marketplace" -type f -name recommended-ask.json 2>/dev/null | head -1 || true)"
          fi
          if [ -n "$_recommended" ] && [ -f "$_settings" ]; then
            _tmp="$(mktemp)"
            if jq -s '.[0] * {permissions: {allow: ((.[0].permissions.allow // []) + .[1] | unique)}}' \
                 "$_settings" "$_recommended" > "$_tmp" 2>/dev/null && [ -s "$_tmp" ]; then
              mv "$_tmp" "$_settings"
            else
              ${flakelabWarn} "could not merge recommended permissions into $_settings."
            fi
            rm -f "$_tmp"
          fi
          if [ -n "$_recommendedask" ] && [ -f "$_settings" ]; then
            _tmp="$(mktemp)"
            if jq -s '.[0] * {permissions: {ask: .[1]}}' \
                 "$_settings" "$_recommendedask" > "$_tmp" 2>/dev/null && [ -s "$_tmp" ]; then
              mv "$_tmp" "$_settings"
            else
              ${flakelabWarn} "could not assert the recommended ask tier in $_settings."
            fi
            rm -f "$_tmp"
          fi
          if [ ! -d "$_marketplace" ]; then
            ${flakelabDefer} "Claude pre-approved permissions not merged: marketplace clone $_marketplace not there yet. Retry: flakelab update"
          elif [ -z "$_recommended" ]; then
            # Distinct from the defer above: the clone is present, so no retry fixes it.
            ${flakelabWarn} "Claude pre-approved permissions not merged: no recommended-permissions.json anywhere under $_marketplace."
          fi
        ''
      );

  # A marker block, not a home.file: Claude appends to this file itself, which a
  # read-only store symlink would break, and anything outside the markers survives.
  # Rewritten every activation, so a restored copy cannot describe another box.
  # Three parts: the neutral core, the per-target file, then claudeMdExtra.
  home.activation.claudeMd =
    lib.hm.dag.entryAfter [ "writeBoundary" "flakelabWarnReset" "claudeDisableAttribution" ]
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
          # Strip the old block first, so this converges instead of appending a copy.
          awk '
            index($0, "<!-- BEGIN managed by flakelab -->") == 1 || index($0, "<!-- BEGIN managed by wslnix -->") == 1 { skip = 1 }
            skip != 1 { print }
            index($0, "<!-- END managed by flakelab -->") == 1 || index($0, "<!-- END managed by wslnix -->") == 1 { skip = 0 }
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
