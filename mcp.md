# Shared MCP accounts and browsers

`mcpShared.servers` registers the same servers in Claude and Codex. On the
credential host, leave `mcpShared.gateway = null`; on other machines set it to
that host's SSH destination. Each client starts an SSH stdio connection to the
host's `flakelab mcp connect <account>`. SSH must already work without a prompt.
The host must be reachable whenever a remote MCP is used. No HTTP MCP port is
opened and SSH agent forwarding is disabled for these connections.

Each account gets its own private directory under
`~/.local/state/flakelab/mcp-auth/`, including accounts using the same endpoint.
The pinned mcp-remote adapter coordinates refreshes on that host. Do not put
this directory, native OAuth files, or live SQLite databases in the history
sync folder. History synchronization continues through `flakelab backup
--state-only`, with its normal merging and secret redaction.

Configure a distinct unprivileged `callbackPort` for every account. From a
desktop, `flakelab mcp login` checks all accounts, opens any required login in
the desktop browser and forwards the loopback callbacks through SSH. There is
no URL to copy out of SSH or tmux. Both agent clients and every configured
machine then use those authorizations. Automatic refresh normally needs no
interaction; a revoked grant may require `flakelab mcp login --fresh <account>`.
`flakelab mcp status` reports whether credentials are stored, not whether a
provider currently accepts them.

To reuse existing Codex file-store authorizations, stop clients that use those
native grants, then run `flakelab mcp import-codex` on their host. The command
matches both account names and URLs, refuses existing adapter directories,
moves the selected grants out of Codex's native store, and preserves a private
rollback copy. Restart the clients with the shared configuration. Never restore
that backup while the shared adapter is using the grants: refresh-token rotation
requires one owner. Keyring-only credentials need a new browser authorization.

`mcpBrowsers.headless = true` registers `playwright-headless` in both clients.
It uses Nix's Chromium headless shell and an isolated context per MCP process.
`mcpBrowsers.bridge = true` also registers `playwright-bridge` on WSL, with the
Windows Chrome extension and the runtime `PLAYWRIGHT_MCP_EXTENSION_TOKEN`.
The headless server removes inherited extension settings. Kiro is unchanged.

Disable replaced marketplace servers using qualified `claudeDisabledPlugins`
names; also remove obsolete user-scope names with `claudeMcpDisabledServers`.
This prevents a bundle dependency from reintroducing a second browser server.
