# Neutral per-user placeholders; a private overlay calling `flakelab.lib.mkSystem`
# supplies the real values, and nix/options.nix documents every field.
# Git-tracked because flakes only evaluate tracked files; secrets never live here.
{
  username = "youruser";
  gitName = "Your Name";
  gitEmail = "you@example.com";
  locale = "en_US.UTF-8";
  windowsUsername = "WindowsUser";
  repoPath = "/mnt/c/Users/WindowsUser/git/flakelab";

  gitEditor = null;

  backupAutostart = false;

  gitlabGroups = [ ];

  repos = [ ];

  sshKeys = [ "id_ed25519" ];

  profiles = [ ];
  profileCliTools = [ ];

  installKiro = true;
  installClaude = true;
  claudeAutoUpdatesChannel = "stable";

  cloneExclude = [ "flakelab" ];

  extraReposDirs = [ ];

  bitwardenServer = null;

  customAliases = { };

  # No secrets: this lands in the world-readable Nix store.
  sessionVariables = { };

  kiroPluginRepo = null;

  claudePluginMarketplaces = [ ];
  claudePluginMarketplace = null;
  claudePlugins = [ ];

  claudeAgentDefaults = false;

  claudeMdExtra = "";

  claudeMcpServers = { };

  whatsappMcpDir = null;
}
