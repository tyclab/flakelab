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
  # renovate: datasource=pypi depName=mcp-synology
  synologyMcpVersion = "0.5.2";
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

  # mcp-synology declares an unbounded 'mcp>=1.0' but imports a module the SDK
  # removed in 2.0.0, so without the 'mcp<2' pin the server crashes on startup.
  synologyServer = {
    command = "uvx";
    args = [
      "--with"
      "mcp<2"
      "mcp-synology==${synologyMcpVersion}"
      "serve"
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
        // lib.optionalAttrs (cfg.sessionVariables ? SYNOLOGY_HOST) {
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
