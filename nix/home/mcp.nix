# MCP server definitions: the version pins, the per-server attrsets, and the
# Kiro server set built from them.
#
# One file because both agents draw on the same definitions: kiro.nix applies
# `mcpServers` to ~/.kiro/settings/mcp.json, and claude.nix builds its own
# user-scope set (claudeMcpServers) from the same attrsets, so the two cannot
# drift. Exported via _module.args.flakelabMcp rather than default.nix's shared
# `flakelab`, so the MCP surface stays one import away from its consumers.
#
# This module adds no activation entry. Should it ever grow one, append it to
# health.nix's flakelabHealthCheck entryAfter list (or give it
# `lib.hm.dag.entryBefore [ "flakelabHealthCheck" ]`), or the health check stops
# being the last entry and reports on work that has not run yet.
{
  lib,
  osConfig,
  ...
}:
let
  cfg = osConfig.flakelab;

  # Per-user: `flakelab clone` lays repos out by GitLab namespace, so this follows
  # the user's own gitlabGroups. null -> whatsapp is skipped.
  inherit (cfg) whatsappMcpDir;

  # MCP server pins (parity with wslkube variables.yaml). Kept as variables so
  # renovate.json's customManagers can see them — an inline pin in an args list
  # has no manager watching it.
  # Windows Chrome as seen from WSL. Single source: the Playwright MCP server
  # below and the Claude env defaults in claude.nix must agree.
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

  # Playwright MCP in extension mode: the Playwright MCP Bridge Chrome extension
  # drives the running Windows Chrome over WebSocket. Extension mode still
  # resolves a Chrome binary to open the extension's connect URL, so
  # --executable-path is required — without it the server throws '"chrome"
  # executable not found' before the extension can attach. The extension
  # auto-updates and cannot be pinned, so the server pin must keep pace or the
  # bridge rejects it with "unsupported protocol version" — hence Renovate
  # tracks it above.
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

  # Home Assistant MCP server (parity with wslkube). Included only when the user
  # has HASS_URL configured (sessionVariables.HASS_URL). Launched via a shell
  # wrapper that maps the runtime HASS_URL/HASS_TOKEN (from ~/.config/tyc/
  # secrets.env) to the HA_URL/HA_TOKEN the server expects — so NO secret is
  # written to the Nix store or mcp.json; it is read from the inherited env.
  homeassistantServer = {
    command = "sh";
    args = [
      "-c"
      ''HA_URL="$HASS_URL" HA_TOKEN="$HASS_TOKEN" exec npx --yes @jarahkon/hass-mcp-server@${hassMcpVersion}''
    ];
  };

  # Proxmox MCP: env var names already match the plugin, so it inherits PROXMOX_*
  # from the shell (sessionVariables + secrets.env) — no wrapper, nothing in the store.
  proxmoxServer = {
    command = "npx";
    args = [
      "--yes"
      "@itunified.io/mcp-proxmox@${proxmoxMcpVersion}"
    ];
  };

  # Synology MCP: same idea — inherits SYNOLOGY_* from the shell (secrets.env).
  # mcp-synology declares an unbounded 'mcp>=1.0' (verified 0.5.2) but imports
  # mcp.server.fastmcp, which the MCP SDK removed in 2.0.0 — pin 'mcp<2' so uvx
  # resolves the 1.x line, else the server crashes on startup (wslkube 788f188).
  synologyServer = {
    command = "uvx";
    args = [
      "--with"
      "mcp<2"
      "mcp-synology==${synologyMcpVersion}"
      "serve"
    ];
  };

  # Grafana MCP (official grafana/mcp-grafana): one server covering Grafana,
  # Prometheus, and Loki (log queries). Env var names already match the server,
  # so it inherits GRAFANA_URL + GRAFANA_SERVICE_ACCOUNT_TOKEN from the shell
  # (sessionVariables + secrets.env) — no wrapper, nothing secret in the store.
  grafanaServer = {
    command = "uvx";
    args = [ "mcp-grafana==${grafanaMcpVersion}" ];
  };

  # WhatsApp MCP (private whatsapp-mcp-extended fork): stdio server run via uv
  # from the cloned repo; talks REST to the Go bridge at WHATSAPP_BRIDGE_HOST.
  # Lean toolsets by default to keep the agent context small; the server can
  # send messages AS the user, so it stays gated on the bridge host being set.
  whatsappServer = {
    command = "sh";
    args = [
      "-c"
      ''BRIDGE_HOST="$WHATSAPP_BRIDGE_HOST" WHATSAPP_MCP_TOOLSETS="''${WHATSAPP_MCP_TOOLSETS:-core,send,media}" exec uv run --directory "${whatsappMcpDir}" python main.py''
    ];
  };

  mcpServers =
    lib.optionalAttrs cfg.mcpPlaywright {
      playwright = playwrightServer;
    }
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
  };

  # Nothing secret is written to the Nix store (see homeassistantServer). These
  # servers are applied by the kiroMcpMerge activation (kiro.nix), not home.file
  # — see the note there.
in
{
  # grafanaServer and whatsappServer are exported individually because
  # claude.nix's user-scope set is built from the same attrsets — the gating
  # there is Claude-specific (it also asks marketplaceOf whether a plugin
  # already ships the server), so the set itself is computed over there while
  # the definitions stay here.
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
