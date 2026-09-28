# Servers registered in both Claude and Codex. Kiro keeps its own registry.
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
in
# The same rules mcp.py enforces at run time, so a bad declaration fails the build.
assert lib.assertMsg (lib.all (name: builtins.match "[a-zA-Z0-9_-]+" name != null) (
  builtins.attrNames cfg.mcpShared.servers
)) "mcpShared.servers: names use letters, digits, underscores and hyphens only";
assert lib.assertMsg (
  lib.all (port: port >= 1024) ports && lib.length (lib.unique ports) == lib.length ports
) "mcpShared.servers: callbackPort values must be distinct and 1024 or above";
{
  inherit launcher;
  servers = lib.mapAttrs (name: _: {
    command = "${launcher}/bin/flakelab-mcp";
    args = [
      "connect"
      name
    ];
  }) cfg.mcpShared.servers;
}
