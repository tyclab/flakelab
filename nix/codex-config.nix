# System defaults stay declarative; Codex owns its writable user configuration.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.flakelab;
  sources = map (path: (builtins.fromJSON (builtins.readFile path)).mcpServers) cfg.codexMcpSources;
  names = lib.concatMap builtins.attrNames sources;
  servers = lib.foldl' (acc: source: acc // source) { } sources;
  nativeServers = lib.mapAttrs (_: server: builtins.removeAttrs server [ "type" ]) servers;
  allServers = nativeServers // (cfg.codexSettings.mcp_servers or { });
  commandRules = import ./codex-rules.nix;
  localRules = lib.concatMapStringsSep "\n" (
    rule:
    "prefix_rule("
    + lib.concatStringsSep ", " (
      lib.mapAttrsToList (name: value: "${name}=${builtins.toJSON value}") rule
    )
    + ")"
  ) commandRules;
  managedRules = map (
    rule:
    builtins.removeAttrs rule [
      "match"
      "not_match"
    ]
    // {
      pattern = map (
        token: if builtins.isList token then { any_of = token; } else { inherit token; }
      ) rule.pattern;
    }
  ) commandRules;
  reviewedServers = lib.mapAttrs (
    name: server:
    server
    // {
      default_tools_approval_mode = "prompt";
      tools =
        lib.genAttrs
          (lib.unique (builtins.attrNames (server.tools or { }) ++ (cfg.codexReadOnlyTools.${name} or [ ])))
          (
            tool:
            (server.tools.${tool} or { })
            // {
              approval_mode =
                if builtins.elem tool (cfg.codexReadOnlyTools.${name} or [ ]) then "approve" else "prompt";
            }
          );
    }
  ) allServers;
  managed =
    cfg.codexSettings != { }
    || cfg.codexMcpSources != [ ]
    || cfg.codexAutoReview
    || cfg.codexEnforcePermissions;
  settings = lib.recursiveUpdate (lib.optionalAttrs cfg.codexAutoReview {
    default_permissions = "flakelab";
    permissions.flakelab = {
      description = "Workspace edits with automatic review of sensitive actions.";
      extends = ":workspace";
      network.enabled = false;
    };
    apps._default = {
      approvals_reviewer = "auto_review";
      default_tools_approval_mode = "prompt";
    };
  }) cfg.codexSettings;
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
        assertion = !cfg.codexEnforcePermissions || cfg.codexAutoReview;
        message = "codexEnforcePermissions requires codexAutoReview";
      }
      {
        assertion =
          !cfg.codexAutoReview
          || !(cfg.codexSettings ? sandbox_mode || cfg.codexSettings ? sandbox_workspace_write);
        message = "codexAutoReview uses native permission profiles; configure permissions.flakelab instead of legacy sandbox_mode/sandbox_workspace_write";
      }
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

    environment.etc = {
      "codex/config.toml".source = (pkgs.formats.toml { }).generate "flakelab-codex-defaults" (
        (
          if cfg.codexEnforcePermissions then
            builtins.removeAttrs settings [
              "permissions"
              "auto_review"
            ]
          else
            settings
        )
        // lib.optionalAttrs (allServers != { }) {
          mcp_servers = if cfg.codexAutoReview then reviewedServers else allServers;
        }
        // lib.optionalAttrs cfg.codexAutoReview {
          approval_policy = "on-request";
          approvals_reviewer = "auto_review";
        }
      );
    }
    // lib.optionalAttrs cfg.codexEnforcePermissions {
      "codex/requirements.toml".source = (pkgs.formats.toml { }).generate "flakelab-codex-requirements" (
        {
          allowed_approval_policies = [ "on-request" ];
          allowed_approvals_reviewers = [ "auto_review" ];
          default_permissions = "flakelab";
          allowed_permission_profiles = {
            flakelab = true;
            ":read-only" = true;
          };
          permissions.flakelab = settings.permissions.flakelab;
          rules.prefix_rules = managedRules;
        }
        // lib.optionalAttrs ((settings.auto_review or { }) ? policy) {
          guardian_policy_config = settings.auto_review.policy;
        }
      );
    };

    home-manager.users.${cfg.username} = { lib, ... }: {
      programs.codex = {
        enable = true;
        # Empty settings leave config.toml writable; keep the official installer.
        package = null;
        rules = lib.optionalAttrs cfg.codexAutoReview { flakelab = localRules; };
      };

      # Migrate only our old config symlink, before Home Manager removes it.
      # Preserve its contents; the same defaults now live in /etc.
      home.activation.codexWritableConfig =
        lib.hm.dag.entryBetween [ "linkGeneration" ] [ "writeBoundary" ]
          ''
            _codex_config="$HOME/.codex/config.toml"
            if [ -z "''${DRY_RUN_CMD:-}" ]; then
              if [ -L "$_codex_config" ]; then
                case "$(${pkgs.coreutils}/bin/readlink -f "$_codex_config")" in
                  /nix/store/*-codex-config)
                    _codex_backup="$(${pkgs.coreutils}/bin/mktemp "$_codex_config.before-system-defaults.XXXXXX")"
                    ${pkgs.coreutils}/bin/install -m600 "$_codex_config" "$_codex_backup"
                    ${pkgs.coreutils}/bin/unlink "$_codex_config"
                    ;;
                esac
              fi
              if [ ! -e "$_codex_config" ] && [ ! -L "$_codex_config" ]; then
                ${pkgs.coreutils}/bin/install -d -m700 "$HOME/.codex"
                ${pkgs.coreutils}/bin/install -m600 /dev/null "$_codex_config"
              fi
            fi
          '';

      xdg.configFile."flakelab/codex-mcp.env".text =
        "# Non-secret MCP host settings; credentials are sourced by launchers at runtime.\n"
        + lib.concatStringsSep "\n" (
          lib.mapAttrsToList (name: value: "export ${name}=${lib.escapeShellArg value}") environment
        )
        + "\n";
    };
  };
}
