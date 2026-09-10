# MCP server definitions: version pins, per-server attrsets, and the Kiro server
# set built from them. One file, so kiro.nix and claude.nix cannot drift; exported
# via _module.args.flakelabMcp.
{
  lib,
  osConfig,
  flakelab,
  ...
}:
let
  cfg = osConfig.flakelab;
  inherit (flakelab) isWsl;

  # null -> whatsapp is skipped.
  inherit (cfg) whatsappMcpDir;

  # Pins live in variables so renovate.json's customManagers can see them; an inline
  # pin in an args list has no manager watching it.
  # This path is the single source claude.nix's env defaults must agree with.
  windowsChromePath = "/mnt/c/Program Files/Google/Chrome/Application/chrome.exe";

  # renovate: datasource=npm depName=@playwright/mcp
  playwrightMcpVersion = "0.0.79";
  # renovate: datasource=npm depName=@jarahkon/hass-mcp-server
  hassMcpVersion = "1.0.10";
  # renovate: datasource=npm depName=@itunified.io/mcp-proxmox
  proxmoxMcpVersion = "2026.4.10-1";
  # Upstream cuts GitHub releases but publishes nothing to PyPI, so the pin is the
  # 1.6.0 release commit. A tag can be moved by a compromised account, a SHA cannot
  # — for this repository; uvx reads no uv.lock and resolves the server's
  # dependencies fresh at every start.
  # renovate-digest: datasource=git-refs depName=https://github.com/atom2ueki/mcp-server-synology
  synologyMcpRev = "95c62c74e8526dd299bfe527063d8e3360ae9ebf";
  # renovate: datasource=pypi depName=mcp-grafana
  grafanaMcpVersion = "1.1.0";

  # Extension mode, driving the running Windows Chrome. --executable-path is still
  # required, or the server throws before the extension can attach. The extension
  # cannot be pinned, so the server pin must keep pace with it.
  playwrightServer = {
    command = "npx";
    args = [
      "--yes"
      "@playwright/mcp@${playwrightMcpVersion}"
      "--executable-path"
      windowsChromePath
      "--extension"
      "--browser"
      "chrome"
    ];
  };

  # The wrapper maps the runtime HASS_* to the HA_* this server expects, so no secret
  # is written to the store or mcp.json.
  homeassistantServer = {
    command = "sh";
    args = [
      "-c"
      ''HA_URL="$HASS_URL" HA_TOKEN="$HASS_TOKEN" exec npx --yes @jarahkon/hass-mcp-server@${hassMcpVersion}''
    ];
  };

  # Env var names already match, so PROXMOX_* is inherited from the shell.
  proxmoxServer = {
    command = "npx";
    args = [
      "--yes"
      "@itunified.io/mcp-proxmox@${proxmoxMcpVersion}"
    ];
  };

  # Fallback only: kiroMcpMerge prefers the mcp-synology plugin's own definition from
  # the Claude marketplace clone, so this runs when that clone is absent. Both are the
  # same pin; bumping it here alone does not change what Kiro runs.
  #
  # DSM hands out its long-lived device token only through the server's settings
  # file -- no env var reads it, and SYNOLOGY_OTP_CODE is spent on the first login.
  # The wrapper materialises that file on tmpfs at start so the password stays in
  # the runtime environment, the same reason homeassistantServer is wrapped. No
  # XDG_RUNTIME_DIR means no tmpfs, and then it refuses rather than write the
  # password somewhere that survives a reboot.
  #
  # The three assignments on the exec line are not defaults being restated: the
  # server reads a generic VERIFY_SSL and defaults it to false for self-signed DSM
  # certs, XIAOZHI bridges it to a foreign WebSocket endpoint, and MCP_HTTP opens an
  # unauthenticated listener. None of the three may follow a stray shell variable.
  synologyServer = {
    command = "sh";
    args = [
      "-c"
      ''
        set -eu
        if [ -n "''${SYNOLOGY_DEVICE_ID:-}" ]; then
          umask 077
          [ -n "''${XDG_RUNTIME_DIR:-}" ] || { echo "synology-mcp: SYNOLOGY_DEVICE_ID is set but XDG_RUNTIME_DIR is not; refusing to write the password to persistent disk" >&2; exit 1; }
          d="$XDG_RUNTIME_DIR/synology-mcp"
          mkdir -p "$d/synology-mcp"
          jq -n --arg u "$SYNOLOGY_URL" --arg n "$SYNOLOGY_USERNAME" \
            --arg p "$SYNOLOGY_PASSWORD" --arg i "$SYNOLOGY_DEVICE_ID" \
            '{synology:{nas:{url:$u,username:$n,password:$p,device_id:$i}}}' \
            > "$d/synology-mcp/settings.json"
          export XDG_CONFIG_HOME="$d"
        fi
        VERIFY_SSL="''${SYNOLOGY_VERIFY_SSL:-true}" ENABLE_XIAOZHI=false MCP_HTTP=false \
          exec uvx --from "git+https://github.com/atom2ueki/mcp-server-synology@${synologyMcpRev}" synology-mcp
      ''
    ];
  };

  # One server covering Grafana, Prometheus and Loki; GRAFANA_* is inherited.
  grafanaServer = {
    command = "uvx";
    args = [ "mcp-grafana==${grafanaMcpVersion}" ];
  };

  # Run from the cloned repo, talking REST to the bridge at WHATSAPP_BRIDGE_HOST.
  # It can send messages as the user, so it stays gated on that host being set.
  whatsappServer = {
    command = "sh";
    args = [
      "-c"
      ''BRIDGE_HOST="$WHATSAPP_BRIDGE_HOST" WHATSAPP_MCP_TOOLSETS="''${WHATSAPP_MCP_TOOLSETS:-core,send,media}" exec uv run --directory "${whatsappMcpDir}" python main.py''
    ];
  };

  mcpServers =
    # Off WSL there is no Windows Chrome, so registering it would hand every agent a
    # broken tool; warn rather than drop the setting silently.
    lib.warnIf (cfg.mcpPlaywright && !isWsl)
      "flakelab.mcpPlaywright is set but flakelab.target is not \"wsl\" — extension mode needs the Windows Chrome path in nix/home/mcp.nix, which is meaningless off WSL; the playwright MCP server was NOT registered."
      (
        lib.optionalAttrs (cfg.mcpPlaywright && isWsl) { playwright = playwrightServer; }
        // lib.optionalAttrs (cfg.sessionVariables ? HASS_URL) {
          homeassistant = homeassistantServer;
        }
        // lib.optionalAttrs (cfg.sessionVariables ? PROXMOX_API_URL) {
          proxmox = proxmoxServer;
        }
        // lib.optionalAttrs (cfg.sessionVariables ? SYNOLOGY_URL) {
          synology = synologyServer;
        }
        // lib.optionalAttrs (cfg.sessionVariables ? GRAFANA_URL) {
          grafana = grafanaServer;
        }
        // lib.optionalAttrs (cfg.sessionVariables ? WHATSAPP_BRIDGE_HOST && whatsappMcpDir != null) {
          whatsapp = whatsappServer;
        }
      );
in
{
  # Two servers are exported individually because claude.nix's gating differs and
  # computes its own set from these definitions.
  _module.args.flakelabMcp = {
    inherit
      mcpServers
      grafanaServer
      whatsappServer
      whatsappMcpDir
      windowsChromePath
      ;
  };
}
