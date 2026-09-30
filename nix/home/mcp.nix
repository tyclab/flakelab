# MCP server definitions: version pins and per-server attrsets, exported via
# _module.args.flakelabMcp so claude.nix builds its set from one source.
{ osConfig, ... }:
let
  cfg = osConfig.flakelab;
  inherit (cfg) whatsappMcpDir;

  # claude.nix's Playwright env defaults read this path, so it is the single source.
  windowsChromePath = "/mnt/c/Program Files/Google/Chrome/Application/chrome.exe";

  # Pins live in variables so renovate.json's customManagers can see them; an inline
  # pin in an args list has no manager watching it.
  # renovate: datasource=pypi depName=mcp-grafana
  grafanaMcpVersion = "1.6.0";

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
in
{
  _module.args.flakelabMcp = {
    inherit
      grafanaServer
      whatsappServer
      whatsappMcpDir
      windowsChromePath
      ;
  };
}
