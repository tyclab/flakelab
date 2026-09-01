# Claude Code: official installer, plugins/marketplaces, settings.json policy
# (attribution, auto mode, statusline, MCP env), ~/.claude.json servers, and
# the managed block in ~/.claude/CLAUDE.md.
#
# Every activation entry here is already named in health.nix's
# flakelabHealthCheck entryAfter list. Any entry added to this module must be
# appended there too (or use `lib.hm.dag.entryBefore [ "flakelabHealthCheck" ]`),
# or the health check stops being the last entry and reports on work that has
# not run yet.
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
    firstSshKey
    sshAgentPreamble
    sshDefer
    flakelabWarn
    flakelabDefer
    ;
  inherit (flakelabMcp)
    grafanaServer
    whatsappServer
    whatsappMcpDir
    windowsChromePath
    ;

  # Which Claude Code release channel the self-updater follows. Claude Code is
  # the one tool this flake deliberately does not pin (installClaudeCode below),
  # so the release channel is the only control left over what lands unreviewed on
  # every box, and "stable" is the baseline. Override per user for early access.
  inherit (cfg) claudeAutoUpdatesChannel;

  # Output style, asserted only when the overlay names one: an unset option
  # leaves the key alone, so a box that never declares a style keeps whatever
  # /output-style last picked there.
  claudeOutputStyleJq = lib.optionalString (cfg.claudeOutputStyle != null) ''
    | .outputStyle = ${builtins.toJSON cfg.claudeOutputStyle}
  '';

  # Auto-mode classifier rules (settings.autoMode), written by the
  # claudeDisableAttribution activation below. Written unconditionally, even where
  # claudeAgentDefaults leaves defaultMode alone: the rules only ever narrow what
  # a session may do, so they cost nothing on a box that never enters auto mode
  # and are already in place on the day one is turned on.
  # User scope is the only scope Claude reads these from — project and local
  # .claude/settings.json are ignored — so a provisioner is the only place they
  # can live and stay reproducible across boxes. The rules themselves, and the
  # tiering note that explains how to change them safely, are the option's
  # default in nix/options.nix.
  inherit (cfg) claudeAutoMode;

  # Passed to jq via --slurpfile rather than an inline single-quoted literal: the
  # environment prose contains apostrophes, which would terminate the shell quote.
  claudeAutoModeFile = pkgs.writeText "claude-automode.json" (builtins.toJSON claudeAutoMode);

  # The permissions.deny FLOOR merged into settings.json. Deny rules are GLOB
  # matchers, not prefix matchers: `*` matches inside the command string, one
  # rule per shape. `--force*` / `-f*` also match the bare flag (a trailing `*`
  # matches the empty string), which catches `git push -f` and keeps
  # `--force-with-lease` denied. Not covered: combined short flags (`-uf`) and
  # `git -c`/`--git-dir=` prefixes - the auto-mode classifier is the second net.
  #
  # A floor, not the whole list: the activation unions these into whatever is
  # already there, so an operator's own deny rules survive every rebuild. Only
  # autoMode is asserted whole.
  claudeDeny = [
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
    "Bash(git push --mirror*)"
  ];

  # The operator's agent-box bundle (flakelab.claudeAgentDefaults), off by
  # default. A jq pipeline fragment appended to the single seeded merge in
  # claudeDisableAttribution below, so it covers the create case with it.
  #
  # defaultMode + skipAutoPermissionPrompt travel together: Claude Code clears the
  # consent flag again whenever defaultMode is not auto. remoteControlAtStartup
  # brings the Remote Control bridge up in every session; user scope is the only
  # scope that can enable it. The del() is part of the bundle, not defensive:
  # those four vars are the only ones gating feature-flag evaluation, which Remote
  # Control needs, so any of them silently defeats remoteControlAtStartup. Removal
  # is the only off switch — DISABLE_TELEMETRY and
  # CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC are raw truthiness, so "0" still
  # blocks. DISABLE_AUTOUPDATER is safe but omitted: it would fight
  # installClaudeCode and autoUpdatesChannel.
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

  # Personal workflow rules appended inside the managed CLAUDE.md block, after
  # the neutral text this repo ships. A store file rather than an inline string,
  # for the same reason claudeAutoModeFile is one: the prose carries quotes.
  # Newline-terminated whatever the overlay wrote, or the END marker lands on the
  # last line of the appended text and the block stops parsing as one.
  claudeMdExtraFile = pkgs.writeText "claude-md-extra.md" (
    lib.removeSuffix "\n" cfg.claudeMdExtra + "\n"
  );
  claudeMdExtraCat = lib.optionalString (
    cfg.claudeMdExtra != ""
  ) "printf '\\n'; cat ${claudeMdExtraFile}";

  # The singular form stays honoured so an overlay predating the list keeps working.
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
  # `plugin install` requires `plugin@marketplace`; bare names stay accepted.
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

  # ── Claude user-scope MCP servers (~/.claude.json) ─────────────────────────
  # Claude keeps user-scope servers in ~/.claude.json, a file it also writes
  # itself, so this is NOT a home.file: the claudeMcpMerge activation below
  # merges the set in. Kiro gets its servers from mcp.json (kiro.nix); Claude only
  # ever got the ones a marketplace plugin happened to ship, so a server this flake
  # defines and no plugin covers reached one agent and not the other.
  #
  # The definitions are the same attrsets the Kiro set uses (nix/home/mcp.nix), so
  # the two agents cannot drift, and the gate is the same sessionVariables one: a
  # server whose credentials are absent can only ever fail, and every registered
  # server costs context tokens in every session (README). Skipped where a
  # marketplace plugin already provides it — two whatsapp servers, which can send
  # messages AS the user, is worse than one. That marketplaceOf gate is why this
  # set is built here and not in mcp.nix: it depends on the Claude plugin list.
  #
  # Per-developer servers (personal checkouts, account names) belong in the
  # overlay's claudeMcpServers, not in a shared repo.
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
  # ── Claude Code (same pattern as kiro-cli) ─────────────────────────────────
  # The nixpkgs build lags behind the version Fable 5 requires. Bootstrap the
  # official native installer into ~/.local/bin once; its auto-updater keeps it
  # current from then on.
  # The binary and its runtime-downloaded helpers (agent teams) run via
  # programs.nix-ld. Guarded so it is a no-op once present.
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

  # ── Claude Code plugins (private marketplaces, opt-in) ─────────────────────
  # Adds each configured marketplace over SSH using the seeded key and installs
  # flakelab.claudePlugins from it — nothing is vendored here. Default [] ->
  # skipped, so a fresh fork installs Claude Code with no extra plugins.
  # Plugin names may be bare ("agents") or fully qualified ("agents@tyc-tools");
  # bare names are qualified with the first marketplace. Installs are idempotent;
  # failures warn instead of blocking activation.
  home.activation.installClaudePlugins =
    lib.hm.dag.entryAfter [ "writeBoundary" "flakelabWarnReset" "installClaudeCode" ]
      (
        lib.optionalString (installClaude && claudeMarketplaces != [ ]) ''
          _claude="$HOME/.local/bin/claude"
          if [ -x "$_claude" ] && [ -f "$HOME/.ssh/${firstSshKey}" ]; then
            export PATH="${
              lib.makeBinPath [
                pkgs.git
                pkgs.openssh
                pkgs.coreutils
              ]
            }:$PATH"
            export GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=accept-new -i $HOME/.ssh/${firstSshKey}"
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
              # A registered marketplace never re-fetches by itself, and `plugin
              # update` resolves versions against the local marketplace clone —
              # a stale marketplace quietly pins every plugin to its last fetch.
              "$_claude" plugin marketplace update ${lib.escapeShellArg m.name} >/dev/null 2>&1 || \
                ${flakelabDefer} "claude marketplace ${m.name} not updated (offline, or no agent key); plugin updates resolve against its last fetch. Retry: flakelab update"
            fi'') claudeMarketplaces}
            # Plugin installs need their marketplace fetched first, so they inherit
            # the same deferral: no agent key or no network means no marketplace,
            # which means nothing to install from.
            for _p in ${lib.concatStringsSep " " qualifiedClaudePlugins}; do
              if "$_claude" plugin install "$_p" >/dev/null 2>&1; then
                # install is a no-op on an installed plugin, so only an explicit
                # update moves the MCP server pinned inside it (@playwright/mcp,
                # whose bridge extension auto-updates past a stale server).
                "$_claude" plugin update "$_p" >/dev/null 2>&1 || \
                  ${flakelabWarn} "claude plugin $_p not updated; it stays on its installed version."
                # Installed is not loaded: a plugin reaches a session only when
                # settings.enabledPlugins names it, and install leaves that key
                # alone. Declaring it in claudePlugins is the opt-in; opt out by
                # dropping it. enable is not a no-op like install — it exits 1
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
            # Claude is there but the key is not: same first-rebuild state as the
            # kiro-plugin clone (kiro.nix). Say so instead of skipping in silence -
            # an operator who is never told has no reason to run `flakelab update`.
            ${flakelabDefer} "claude marketplaces and plugins not installed: no ~/.ssh/${firstSshKey} yet, so the git@ marketplaces could not be fetched. Provisioning seeds the key after this rebuild; flakelab update then completes it."
          fi
        ''
      );

  # ── Prune opted-out MCP plugins (parity with wslkube tasks/claude.yaml) ────
  # Converge to the declared list: an mcp-* plugin from one of our marketplaces
  # that claudePlugins no longer names is uninstalled. Scoped to mcp-*@<our
  # marketplaces>, so core plugins and other marketplaces are left untouched.
  # </dev/null bounds any interactive prompt. A failed uninstall leaves an
  # opted-out MCP server loading its tools into every session, so it is a
  # warning the health check fails the rebuild on.
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
              # Assigned separately (not inline in the loop), so a corrupt registry
              # or a schema change aborts the pass instead of looking like
              # "nothing to prune".
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

  # ── Claude Code attribution + settings policy ──────────────────────────────
  # Claude Code appends a "Generated with Claude Code" footer to PR/MR bodies
  # and a "Co-Authored-By: Claude" trailer to commits by default. Set both
  # attribution fields to "" so neither is added. Idempotent jq merge that
  # preserves any other user-set attribution keys and creates settings.json if
  # absent. Failures warn instead of blocking activation.
  # autoMode (the classifier's allow/soft_deny/hard_deny/environment rules, see
  # claudeAutoMode above) is asserted wholesale: it is policy, and a box that
  # drifted from it is a box whose blocks nobody can predict. Note Claude Code
  # itself refuses to let an agent edit this key, so the provisioner is also the
  # only practical way to change it under automation. The deny list is a floor
  # (union), so a rule the developer added by hand survives.
  # Feedback and error reporting are off; telemetry is left alone either way.
  # The rate setting covers the session-quality survey, the env var also covers
  # the transcript-share follow-up that survey offers.
  #
  # installMethod records how Claude got here, and it IS the native installer
  # (home.activation.installClaudeCode above), so the value is asserted rather
  # than left to whatever wrote the file last. autoUpdatesChannel comes from
  # the claudeAutoUpdatesChannel option. Neither was ever written by a rebuild,
  # so a clean build produced a settings.json missing keys a provisioned box has.
  #
  # Everything above is written for every adopter. Auto mode, its consent flag,
  # Remote Control at startup and the four env-var deletions are NOT: they are
  # the opt-in bundle claudeAgentDefaultsJq carries (flakelab.claudeAgentDefaults,
  # default false). Gated on installClaude like every sibling here — without
  # Claude Code there is no settings.json worth writing.
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
          mkdir -p "$HOME/.claude"
          # Seed rather than branch: `{}` is the identity for every filter below, so
          # one merge covers the create case too. `-s` and not `-f`, so a zero-byte
          # settings.json heals; a corrupt one still warns.
          [ -s "$_settings" ] || printf '{}' > "$_settings"
          jq --argjson a "$_attrs" --argjson e "$_env" --argjson d "$_deny" --slurpfile am ${claudeAutoModeFile} '
            .attribution = ($a + (.attribution // {}))
            | .feedbackSurveyRate = 0
            | .env += $e
            | .installMethod = "native"
            | .autoUpdatesChannel = "${claudeAutoUpdatesChannel}"
            | .autoMode = $am[0]
            | .permissions.deny = ((.permissions.deny // []) + $d | unique)
            ${claudeOutputStyleJq}
            ${claudeAgentDefaultsJq}
          ' "$_settings" > "$_settings.tmp" && mv "$_settings.tmp" "$_settings" || {
            rm -f "$_settings.tmp"
            ${flakelabWarn} "could not update Claude attribution in $_settings."
          }
          # env carries MCP credentials and `flakelab backup` archives this file whole. The
          # merge above replaces the inode, so the mode is reasserted every
          # activation rather than set once.
          chmod 600 "$_settings"
        ''
      );

  # ── Claude Code statusline (statusbar plugin; parity with wslkube db819ae) ──
  # Installing the plugin only caches the script — settings.json must point
  # statusLine at it or no bar renders. Idempotent: only writes when the key is
  # absent, so local overrides survive re-provisioning. The sort -V glob
  # resolves the newest cached plugin version, so updates don't break the wiring.
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

  # ── Playwright MCP bridge env for Claude (parity with wslkube 94f8127) ─────
  # The mcp-playwright marketplace plugin reads PLAYWRIGHT_MCP_* from
  # settings.json env. Values are non-secret and fixed by the bridge design.
  # Without them the server launches a local chrome and fails ('"chrome"
  # executable not found') instead of attaching to Windows Chrome. `isWsl` in
  # the gate: windowsChromePath is meaningless off WSL (mcp.nix already skips
  # registering the server there; this stops writing its env too).
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

  # ── WhatsApp MCP bridge env for Claude (parity with wslkube tasks/claude.yaml) ─
  # The mcp-whatsapp marketplace plugin expands ${WHATSAPP_MCP_DIR} and
  # ${WHATSAPP_BRIDGE_HOST} from settings.json env; without them the plugin
  # resolves them to empty and the server cannot find its checkout or the bridge.
  # Only the three NON-SECRET values are written here — WHATSAPP_API_KEY stays in
  # ~/.config/tyc/secrets.env and reaches the plugin through the shell env, the
  # same way the synology/grafana/proxmox servers get their credentials.
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

  # ── Claude user-scope MCP servers (~/.claude.json) ─────────────────────────
  # Register claudeMcpServers at user scope. `claude mcp add` is one-shot — it
  # refuses a name that already exists — so this converges on the same file it
  # writes instead: our declared servers are (re)asserted, anything the developer
  # added by hand survives untouched. Idempotent and safe to re-run.
  #
  # `+` and not jq's recursive `*`: a server definition must be replaced whole, or
  # an arg dropped from the declaration here would linger in the file forever.
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
            # 600, not 644: the same file carries the account and OAuth state that
            # Claude writes next to these servers.
            $DRY_RUN_CMD install -m600 "$_tmp" "$_claudeJson"
          else
            ${flakelabWarn} "could not merge Claude MCP servers into $_claudeJson; leaving it intact."
          fi
          rm -f "$_tmp"
        ''
      );

  # ── Claude Code pre-approved permissions ───────────────────────────────────
  # Without a pre-approved list Claude prompts for routine work, and no rebuild
  # ever wrote one. The rules are NOT copied into this repo: the marketplace ships
  # recommended-permissions.json and updates it as it grows tools, so the clone is
  # the source and this only merges. Union + unique: additive, so a rule the
  # developer added by hand is kept, and re-running changes nothing.
  #
  # Such a list is broad by design — prompts train people to click through — so it
  # is only safe while something narrower sits behind it. That backstop is the auto
  # mode classifier (claudeAutoMode above), which evaluates every call the list
  # pre-approves and blocks on semantics rather than pattern.
  #
  # claudeDisableAttribution writes those rules on every box that has Claude at
  # all, independently of claudeAgentDefaults — which is why this is gated on
  # installClaude and nothing narrower.
  #
  # The marketplace is a path dependency, not a safety boundary: it is where
  # recommended-permissions.json is read from. Any marketplace serves, so the first
  # one is used rather than a specific plugin's.
  #
  # The file is located, not assumed. It was read from a hardcoded `docs/` path
  # that the marketplace has never had, so the merge deferred on every rebuild
  # since it was written and the allow-list was never once applied — a silent
  # forever-defer, because a missing file is a legitimate not-yet-cloned state.
  # `find` over the clone survives the next reorganisation too; it is bounded to
  # one marketplace and the name is specific enough not to collide.
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
              # `find` is findutils, not coreutils — without it the locate below
              # resolves nothing and the merge silently never happens again.
              pkgs.findutils
            ]
          }:$PATH"
          # This activation runs only when the built config changed, while the
          # marketplace clone is runtime data — nix-update therefore replays
          # this same merge (and the marketplace refresh) unconditionally after
          # every successful switch; keep the jq union here and there in sync.
          _settings="$HOME/.claude/settings.json"
          _marketplace="$HOME/.claude/plugins/marketplaces/${firstMarketplace}"
          # find runs only when the clone exists: on a missing directory it exits
          # non-zero, and the activation script's `set -eu -o pipefail` turns that
          # command substitution into a silent abort of the WHOLE activation —
          # which is precisely the state of every fresh machine's first rebuild,
          # where the clone is still deferred behind the not-yet-seeded SSH key.
          # (Crashed a second machine's provision on 2026-08-20; the box this was
          # written on had the clone, so it never showed.)
          _recommended=""
          if [ -d "$_marketplace" ]; then
            _recommended="$(find "$_marketplace" -type f -name recommended-permissions.json 2>/dev/null | head -1 || true)"
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
          elif [ ! -d "$_marketplace" ]; then
            # Not a failure: the marketplace clone lands with installClaudePlugins,
            # which defers when there is no agent key or no network. `flakelab update`
            # replays both in order.
            ${flakelabDefer} "Claude pre-approved permissions not merged: marketplace clone $_marketplace not there yet. Retry: flakelab update"
          else
            # Distinct from the defer above on purpose. The clone IS present and
            # the file is not in it, which no retry fixes — that is the shape the
            # hardcoded `docs/` path had, and it deferred quietly for months.
            ${flakelabWarn} "Claude pre-approved permissions not merged: no recommended-permissions.json anywhere under $_marketplace."
          fi
        ''
      );

  # ── Claude global memory (~/.claude/CLAUDE.md) ─────────────────────────────
  # A marker block, not a home.file: Claude appends to this file itself (the `#`
  # memory shortcut), and a read-only store symlink would make that fail.
  # Everything outside the markers is left alone, so any note the developer added
  # survives.
  #
  # The block is rewritten every activation, which is what makes the content this
  # repo's. Until now the file was whatever `flakelab backup` had restored — a per-instance
  # artifact no rebuild refreshed, so a distro could describe an environment it is
  # not.
  #
  # Three parts, in order: the target-neutral core this repo ships (facts about
  # the distro EVERY adopter gets, on any target), the per-target file
  # (target-wsl.md or target-proxmox-vm.md — the enum in nix/options.nix has no
  # third answer, so `cfg.target` alone picks the right one), then
  # flakelab.claudeMdExtra (default "", so nothing is appended) for the personal
  # workflow rules that used to be shipped alongside them.
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
          # Strip our own block (and the pre-rename wslnix one) first, so this
          # converges instead of appending a copy of itself on every rebuild.
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
