{
  description = "Private flakelab overlay - real personal values, kept off the shareable template";

  # Both generators rewrite this whole line, keyed on the marker comment: keep the
  # marker, exactly once, and keep the line on one line.
  # Git-ignore this overlay's flake.lock: a committed lock pins a local checkout's
  # NAR hash and the next edit there aborts the build with "NAR hash mismatch".
  inputs.flakelab.url = "github:tyclab/flakelab"; # flakelab-url: substitution anchor

  outputs =
    { flakelab, ... }:
    {
      # flakelab/nix/options.nix is the schema: a misspelt key or wrong type aborts
      # evaluation, and every option declared there without a default must be set here.
      # No plaintext secrets - the Nix store is world-readable; use sopsSecretsFile
      # or ~/.config/tyc/secrets.env.
      nixosConfigurations.default = flakelab.lib.mkSystem {
        # Platform to build for; set on a Proxmox guest, never on a WSL distro.
        # target = "proxmox-vm";

        username = "CHANGEME"; # Linux user (no dashes)
        gitName = "CHANGEME";
        gitEmail = "changeme@example.com";
        locale = "en_US.UTF-8";
        windowsUsername = "WindowsUser"; # your C:\Users\<name> folder - WSL only; null elsewhere
        repoPath = "/mnt/c/Users/WindowsUser/git/flakelab-config"; # this flake

        gitEditor = null; # null -> leave the git default
        backupAutostart = false;

        # This distro's hostname.
        # hostName = "flakelab";

        # A second root for the shareable backup state, replicated by your sync
        # client. Never a git checkout, never inside repoPath.
        # stateRoot = "/mnt/d/sync/flakelab-state";
        # Session transcripts too (large, and the verbatim text of every session):
        # stateTranscripts = true;

        # Which flakelab/profiles/ entries apply; an entry may also be an imported
        # profile attrset, which this overlay must `git add` before switching.
        profiles = [
          "example"
        ];

        # Personal full-clone GitLab groups; profile groups are unioned in.
        gitlabGroups = [ ];

        # Repos to keep out of ~/git.
        cloneExclude = [
          "flakelab"
          "flakelab-config"
        ];

        # Extra roots for the gitcheck/gitclean aliases beyond ~/git.
        extraReposDirs = [ "/mnt/c/Users/WindowsUser/git" ];

        # Keys under files/config/shared/ssh/keys/ to load on login; the first is
        # the git/clone identity.
        # sshKeys = [ "id_ed25519" ];

        # Non-secret config only - these land in the Nix store - and each entry
        # gates its MCP server in flakelab/nix/home/mcp.nix.
        # sessionVariables = {
        #   HASS_URL = "http://homeassistant.example.lan:8123";
        #   PROXMOX_API_URL = "https://pve.example.lan:8006"; # no /api2/json
        #   PROXMOX_VERIFY_SSL = "false";
        #   SYNOLOGY_URL = "https://nas.example.com:443"; # scheme, host and port
        #   SYNOLOGY_VERIFY_SSL = "true";
        #   SYNOLOGY_USERNAME = "mcp-service"; # non-admin, not in administrators
        #   GRAFANA_URL = "https://grafana.example.lan";
        #   WHATSAPP_BRIDGE_HOST = "localhost:8180";
        # };

        # customAliases = { proxmox-ssh = "ssh root@pve.example.lan"; };

        # Private kiro plugin repo to clone and install.
        # kiroPluginRepo = "git@gitlab.com:you/kiro-plugin.git";
        # Claude plugin marketplaces to register.
        # claudePluginMarketplaces = [
        #   {
        #     # Must match the `name` in the marketplace's own
        #     # .claude-plugin/marketplace.json - a wrong name installs nothing.
        #     name = "your-tools";
        #     url = "git@gitlab.com:you/claude-plugins.git";
        #   }
        # ];
        # Plugins to install from those marketplaces.
        # claudePlugins = [ "agents" "skills" "hooks" "statusbar" ];

        # The agent-box bundle: turn on only for a box meant to run agents unattended.
        # claudeAgentDefaults = true;

        # Your own rules, appended inside the managed block of ~/.claude/CLAUDE.md.
        # claudeMdExtra = ''
        #   ## Workflow Preferences
        #
        #   - `glab` for the GitLab repos under `~/git`; `gh` only for GitHub remotes.
        # '';

        # Per-developer Claude user-scope MCP servers, merged into ~/.claude.json.
        # claudeMcpServers = {
        #   scratch = {
        #     type = "stdio";
        #     command = "node";
        #     args = [ "/home/CHANGEME/git/.../dist/index.js" ];
        #   };
        # };

        # Absolute path to the whatsapp-mcp-server checkout.
        # whatsappMcpDir = "/home/CHANGEME/git/.../whatsapp-mcp-server";

        # Endpoint `bw config server` is pointed at on every rebuild.
        # bitwardenServer = "https://vault.bitwarden.eu";
      };
    };
}
