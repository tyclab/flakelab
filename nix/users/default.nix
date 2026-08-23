# Per-user + team values (replaces files/config/user_data.yaml + variables.yaml).
#
# THIS FILE SHIPS NEUTRAL PLACEHOLDERS. It is git-tracked because Nix flakes only
# evaluate files that are tracked by git — a git-ignored config would be invisible
# to `nixos-rebuild --flake`, so the Ansible-style "example + git-ignored real
# file" split does not work here.
#
# Two ways to use your own values:
#   1. Fork this repo and edit the values below, committing to your fork.
#   2. (Recommended, keeps private data off a public repo) Leave this file as-is
#      and build from a small PRIVATE overlay flake that calls
#      `flakelab.lib.mkSystem { <your values> }`. See README "Where configuration
#      lives".
#
# Secrets (GITLAB_TOKEN, GH_TOKEN, HASS_TOKEN, PROXMOX_TOKEN_*, SYNOLOGY_PASSWORD,
# SYNOLOGY_DEVICE_ID, GRAFANA_SERVICE_ACCOUNT_TOKEN) are NOT here
# — they are provided at runtime via the environment (from OpenBao; see
# nix/home and files/config/secrets.env.example).
{
  username = "youruser";
  gitName = "Your Name";
  gitEmail = "you@example.com";
  locale = "en_US.UTF-8";
  windowsUsername = "WindowsUser"; # your C:\Users\<name> folder
  repoPath = "/mnt/c/Users/WindowsUser/git/flakelab"; # the flake you rebuild from

  # git editor override (user_data.giteditor). null -> leave git default.
  gitEditor = null;

  # Run `flakelab backup --force` daily from a systemd user timer (nix/home/backup.nix).
  backupAutostart = false;

  # Profile groups are unioned in here by the flake's merge step.
  gitlabGroups = [ ];

  # Extra repos beyond group discovery; relPath is relative to ~/git. These
  # bypass cloneExclude, since naming a repo here is already explicit.
  # e.g. [ { relPath = "tools/foo"; url = "git@gitlab.com:you/foo.git"; } ]
  repos = [ ];

  # The FIRST entry is the git/clone key; the rest are agent-loaded too.
  sshKeys = [ "id_ed25519" ];

  # Zero or more profiles/ entries; the shipped one is `example`.
  profiles = [ ];
  profileCliTools = [ ]; # additive on top of the profile-derived set

  installKiro = true;
  installClaude = true;
  claudeAutoUpdatesChannel = "stable"; # Claude self-updater channel; "latest" for early access

  # Repo names to skip during GitLab group discovery (this repo lives on the
  # Windows mount only, so no need to clone it into ~/git).
  cloneExclude = [ "flakelab" ];

  # Extra roots the gitcheck/gitclean aliases scan beyond ~/git — e.g. a
  # Windows-mount tree that still holds clones existing nowhere else:
  # [ "/mnt/c/Users/WindowsUser/git" ]
  extraReposDirs = [ ];

  # Endpoint the Bitwarden CLI is pointed at (`bw config server`). null leaves
  # the CLI wherever it already points; name a region here — the EU one is
  # "https://vault.bitwarden.eu" — and every rebuild asserts it.
  bitwardenServer = null;

  # Personal shell aliases (user_data.custom_aliases).
  customAliases = { };

  # Non-secret env vars (user_data.custom_env_vars minus the secrets).
  sessionVariables = { };

  # ── Opt-in private integrations ────────────────────────────────────────────
  # These pull from PRIVATE GitLab repos, so they default to off: a fresh fork
  # builds cleanly with the AI CLIs installed but no extra plugins. Set them in
  # your private overlay to re-enable.

  # Kiro plugin repo (agents/steering/hooks/skills via `make install-global`).
  # null -> skip. Example: "git@gitlab.com:you/kiro-plugin.git".
  kiroPluginRepo = null;

  # claudePluginMarketplaces is canonical; the singular form is still honoured.
  #   [ { name = "your-tools"; url = "git@gitlab.com:you/claude-plugins.git"; } ]
  claudePluginMarketplaces = [ ];
  claudePluginMarketplace = null;
  # Bare names resolve to the first marketplace; `plugin@marketplace` also works.
  claudePlugins = [ ]; # e.g. [ "agents" "skills" "lsp-servers" "hooks" "statusbar" ]

  # The operator's agent-box bundle: auto mode with its consent flag, Remote
  # Control at startup, and removal of the four env vars that would defeat it.
  # Off by default — that is a policy to choose, not something installing Claude
  # Code should hand you (see nix/options.nix claudeAgentDefaults).
  claudeAgentDefaults = false;

  # Personal workflow rules appended inside the managed block of
  # ~/.claude/CLAUDE.md, after the neutral text files/config/claude/CLAUDE.md
  # ships. Empty here on purpose: which forge CLI to reach for, which agents to
  # prefer, how to housekeep after a merge — none of that is a fact about the
  # distro, so it belongs to whoever runs the box.
  claudeMdExtra = "";

  # Extra Claude user-scope MCP servers, merged into ~/.claude.json on every
  # rebuild (see nix/home claudeMcpServers / claudeMcpMerge). The servers this
  # flake defines are already declared there; this is where per-developer ones go,
  # so personal paths and account names stay out of a shared repo. Same shape as
  # ~/.claude.json's own `mcpServers` entries, e.g.
  #   claudeMcpServers = {
  #     scratch = {
  #       type = "stdio";
  #       command = "node";
  #       args = [ "/home/<you>/git/<something>/dist/index.js" ];
  #     };
  #   };
  claudeMcpServers = { };

  # Absolute path to the whatsapp-mcp-server checkout. Depends on your
  # gitlabGroups, since clones follow the GitLab namespace. null -> skipped.
  whatsappMcpDir = null;
}
