# Servers registered in both Claude and Codex: the shared OAuth accounts and the
# headless browser.
{ pkgs, cfg }:
let
  inherit (pkgs) lib;
  # renovate: datasource=npm depName=mcp-remote
  remoteVersion = "0.14.3";
  settings = pkgs.writeText "flakelab-mcp.json" (
    builtins.toJSON {
      inherit remoteVersion;
      inherit (cfg.mcpShared) gateway servers;
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
    exec ${pkgs.zsh}/bin/zsh ${../files/scripts}/mcp "$@"
  '';
  ports = lib.mapAttrsToList (_: server: server.callbackPort) cfg.mcpShared.servers;

  # Playwright's MCP server from the nixpkgs build, not @playwright/mcp from npm:
  # that package is a cli.js over playwright-core, pinned to an alpha no nixpkgs
  # browser build matches. Taking the server and the headless shell from one
  # playwright-driver keeps them paired; playwright-core finds the shell by the
  # revision in its browsers.json and refuses to launch on a mismatch.
  playwrightCore = pkgs.playwright-driver;
  # The headless shell alone, the same store path the full browser set links.
  headlessShell = playwrightCore.browsers.override {
    withChromium = false;
    withFirefox = false;
    withWebkit = false;
    withFfmpeg = false;
  };
  playwrightMcpCli = pkgs.writeText "playwright-mcp-cli.js" ''
    const { program } = require("${playwrightCore}/lib/utilsBundle");
    const { tools } = require("${playwrightCore}/lib/coreBundle");
    tools.decorateMCPCommand(
      program.version("Version ${playwrightCore.version}").name("Playwright MCP"),
      "${playwrightCore.version}",
    );
    void program.parseAsync(process.argv);
  '';
  # browserName without a channel: `--browser chromium` would select the full
  # Chrome for Testing build, and only a channel-less headless launch uses the shell.
  headlessConfig = pkgs.writeText "playwright-headless.json" (
    builtins.toJSON {
      browser = {
        browserName = "chromium";
        isolated = true;
        launchOptions.headless = true;
      };
      imageResponses = "omit";
    }
  );
  headless = pkgs.writeShellScriptBin "flakelab-playwright-headless" ''
    # The bridge's PLAYWRIGHT_MCP_* settings reach every MCP server through the
    # clients' environment and would turn this one into a second bridge.
    for _var in ''${!PLAYWRIGHT_MCP_@}; do
      unset "$_var"
    done
    export PLAYWRIGHT_BROWSERS_PATH=${headlessShell}
    export PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
    exec ${pkgs.nodejs_24}/bin/node ${playwrightMcpCli} --config ${headlessConfig} "$@"
  '';
in
# The only check of names and ports: mcp.py reads the file these guard.
assert lib.assertMsg (lib.all (name: builtins.match "[a-zA-Z0-9_-]+" name != null) (
  builtins.attrNames cfg.mcpShared.servers
)) "mcpShared.servers: names use letters, digits, underscores and hyphens only";
assert lib.assertMsg (
  lib.all (port: port >= 1024) ports && lib.length (lib.unique ports) == lib.length ports
) "mcpShared.servers: callbackPort values must be distinct and 1024 or above";
assert lib.assertMsg (
  !(cfg.mcpBrowsers.headless && cfg.mcpShared.servers ? playwright-headless)
) "mcpShared.servers: playwright-headless is the name mcpBrowsers.headless registers";
{
  inherit launcher;
  servers =
    lib.mapAttrs (name: _: {
      command = "${launcher}/bin/flakelab-mcp";
      args = [
        "connect"
        name
      ];
    }) cfg.mcpShared.servers
    // lib.optionalAttrs cfg.mcpBrowsers.headless {
      playwright-headless = {
        command = "${headless}/bin/flakelab-playwright-headless";
        args = [ ];
      };
    };
}
