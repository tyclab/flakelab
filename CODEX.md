# Codex MCP and permissions

Nix generates Codex's native system defaults at `/etc/codex/config.toml`.
The pinned Home Manager `programs.codex` module manages command rules; Home
Manager also generates non-secret MCP host settings. There is no custom
configuration merger or runtime plugin installer.

Add the separate MCP repository as a `flake = false` input in the private overlay:

```nix
inputs.codex-mcp = {
  url = "git+ssh://git@gitlab.com/your-group/codex-plugins.git";
  flake = false;
};
```

Receive `codex-mcp` in `outputs` and select files in `userData`:

```nix
codexMcpSources = [
  (codex-mcp + "/plugins/mcp-grafana/.mcp.json")
];
codexAutoReview = true;
codexReadOnlyTools.grafana = [ "list_datasources" "search_dashboards" ];
codexSettings = {
  tui.status_line = [
    "model-with-reasoning" "context-remaining" "git-branch" "current-dir"
  ];
};
```

`flake.lock` pins the MCP source. Fetching a private input uses the operator's Git
authentication; credentials never enter Nix expressions or the store. After the
input is fetched, configuration building and activation need no marketplace
network operation. Removing a source removes its servers on the next switch;
rolling back the generation restores the prior configuration.

`~/.codex/config.toml` stays writable: Codex saves trust decisions, model selections
and UI changes there. User and trusted project settings override the system
defaults. Put fleet defaults in `codexSettings` and remove conflicting user
overrides when a fleet change should take effect. These defaults are not enforced
`requirements.toml` constraints.

Activation migrates the earlier Home Manager `codex-config` symlink to an empty,
mode-600 user file and saves its contents as `config.toml.before-system-defaults.*`.
Existing regular user files are preserved. Auth, OAuth tokens, sessions and caches
remain runtime state. Do not also enable the same servers as Codex plugins: that
creates duplicate tools. Plugins remain available outside Flakelab.

The TycLabs launchers obtain credentials from flakelab's existing zsh runtime
secret source. `~/.config/flakelab/codex-mcp.env` contains only the configured
WhatsApp checkout and, on WSL, Chrome settings. Claude files, skills, agents and
hooks are independent and unchanged.

`codexAutoReview` selects `on-request`, `auto_review`, and `workspace-write` with
sandbox networking disabled. Every configured MCP server requires approval,
except exact names in `codexReadOnlyTools`. Cloudflare execution, infrastructure
mutations, browser actions and WhatsApp sends have no automatic grants.
`files/config/codex.rules` routes sensitive command prefixes to review and rejects
the listed mirror-push forms. Personal rule files remain separate.

Codex reviews approval events, not every shell command. Prefix rules do not cover
every possible argv spelling or indirect execution. The built-in reviewer policy
is retained; Claude's prose classifier rules and CI-enrichment hooks are not
copied. Service token scopes, forge branch protection and CI requirements remain
independent enforcement.

Verify with `nix flake check`, `codex mcp list`, and `/mcp` in a fresh thread.
`checks.x86_64-linux.codex-config` checks opt-in defaults, generated settings,
MCP policy and isolation. Use `codex execpolicy check --rules FILE -- COMMAND` for
command-rule cases. MCP registration and successful service authentication are
separate checks; Cloudflare API access requires its own OAuth login.
The check also exercises symlink migration, private backups, writable trust
settings, dry runs, and preservation of subsequent user changes.

To exclude a server from Claude as well, remove its entry from `claudePlugins`
and set `claudeMcpDisabledServers = [ "whatsapp" ];` for the native server name.
This prevents the legacy native fallback from recreating it after plugin removal.
The exclusion does not change Kiro's configuration.

References: [Home Manager Codex options](https://nix-community.github.io/home-manager/options/home-manager/programs/codex.html),
[Nix flake inputs and lock files](https://nix.dev/manual/nix/stable/command-ref/new-cli/nix3-flake.html),
[Codex configuration layers](https://learn.chatgpt.com/docs/config-file/config-basic),
[Codex Auto-review](https://learn.chatgpt.com/docs/sandboxing/auto-review),
[Codex command rules](https://learn.chatgpt.com/docs/agent-configuration/rules).
