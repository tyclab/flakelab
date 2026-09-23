# Native Home Manager configuration. Inputs are locked by the private overlay;
# evaluation/build never inspect the live home, credentials or Codex caches.
{
  lib,
  osConfig,
  ...
}:
let
  cfg = osConfig.flakelab;
  sources = map (path: (builtins.fromJSON (builtins.readFile path)).mcpServers) cfg.codexMcpSources;
  names = lib.concatMap builtins.attrNames sources;
  servers = lib.foldl' (acc: source: acc // source) { } sources;
  nativeServers = lib.mapAttrs (_: server: builtins.removeAttrs server [ "type" ]) servers;
  allServers = nativeServers // (cfg.codexSettings.mcp_servers or { });
  reviewedServers = lib.mapAttrs (
    name: server:
    server
    // {
      default_tools_approval_mode = "prompt";
      tools = lib.genAttrs (cfg.codexReadOnlyTools.${name} or [ ]) (_: {
        approval_mode = "approve";
      });
    }
  ) allServers;
  managed = cfg.codexSettings != { } || cfg.codexMcpSources != [ ] || cfg.codexAutoReview;
  environment =
    lib.optionalAttrs (cfg.whatsappMcpDir != null) { WHATSAPP_MCP_DIR = cfg.whatsappMcpDir; }
    // lib.optionalAttrs (cfg.target == "wsl") {
      PLAYWRIGHT_MCP_EXECUTABLE_PATH = "/mnt/c/Program Files/Google/Chrome/Application/chrome.exe";
      PLAYWRIGHT_MCP_BROWSER = "chrome";
    };
in
{
  config = lib.mkIf (cfg.installCodex && managed) {
    assertions = [
      {
        assertion = builtins.length names == builtins.length (lib.unique names);
        message = "codexMcpSources contains duplicate server names";
      }
      {
        assertion = lib.all (name: builtins.hasAttr name allServers) (
          builtins.attrNames cfg.codexReadOnlyTools
        );
        message = "codexReadOnlyTools names an unconfigured MCP server";
      }
      {
        assertion = lib.all (name: builtins.match "[A-Za-z0-9_.-]+" name != null) (
          lib.concatLists (builtins.attrValues cfg.codexReadOnlyTools)
        );
        message = "codexReadOnlyTools requires exact tool names, never wildcards";
      }
    ];

    programs.codex = {
      enable = true;
      # Keep flakelab's existing official CLI installer/version policy.
      package = null;
      settings =
        cfg.codexSettings
        // lib.optionalAttrs (allServers != { }) {
          mcp_servers = if cfg.codexAutoReview then reviewedServers else allServers;
        }
        // lib.optionalAttrs cfg.codexAutoReview {
          approval_policy = "on-request";
          approvals_reviewer = "auto_review";
          sandbox_mode = "workspace-write";
          sandbox_workspace_write = (cfg.codexSettings.sandbox_workspace_write or { }) // {
            network_access = false;
          };
        };
      rules = lib.optionalAttrs cfg.codexAutoReview { flakelab = ../../files/config/codex.rules; };
    };

    xdg.configFile."flakelab/codex-mcp.env".text =
      "# Non-secret MCP host settings; credentials are sourced by launchers at runtime.\n"
      + lib.concatStringsSep "\n" (
        lib.mapAttrsToList (name: value: "export ${name}=${lib.escapeShellArg value}") environment
      )
      + "\n";
  };
}
