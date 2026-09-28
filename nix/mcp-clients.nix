# Shared Claude/Codex servers. Kiro keeps its existing registry.
{ pkgs, cfg }:
let
  inherit (pkgs) lib;
  # renovate: datasource=npm depName=mcp-remote
  remoteVersion = "0.14.3";
  # renovate: datasource=npm depName=@playwright/mcp
  playwrightVersion = "0.0.82";
  settings = pkgs.writeText "flakelab-mcp.json" (
    builtins.toJSON {
      inherit remoteVersion playwrightVersion;
      inherit (cfg.mcpShared) gateway servers;
      inherit (cfg.mcpBrowsers) headless bridge;
      browsersPath = lib.optionalString cfg.mcpBrowsers.headless "${pkgs.playwright-driver.browsers}";
      chromePath = "/mnt/c/Program Files/Google/Chrome/Application/chrome.exe";
    }
  );
  launcher = pkgs.writeShellScriptBin "flakelab-mcp" ''
    export PATH=${
      lib.makeBinPath [
        pkgs.python3
        pkgs.nodejs_24
        pkgs.openssh
        pkgs.zsh
      ]
    }:$PATH
    export FLAKELAB_MCP_CONFIG=${settings}
    # zshenv loads the configured runtime secrets (including the bridge token).
    exec ${pkgs.zsh}/bin/zsh ${../files/scripts}/mcp "$@"
  '';
  server = args: {
    command = "${launcher}/bin/flakelab-mcp";
    inherit args;
  };
in
assert lib.assertMsg (
  !cfg.mcpBrowsers.bridge || cfg.target == "wsl"
) "mcpBrowsers.bridge requires WSL with the Windows Chrome extension";
{
  inherit launcher;
  servers =
    lib.mapAttrs (
      name: _:
      server [
        "connect"
        name
      ]
    ) cfg.mcpShared.servers
    // lib.optionalAttrs cfg.mcpBrowsers.headless {
      playwright-headless = server [
        "browser"
        "headless"
      ];
    }
    // lib.optionalAttrs cfg.mcpBrowsers.bridge {
      playwright-bridge = server [
        "browser"
        "bridge"
      ];
    };
}
