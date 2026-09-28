# Shared MCP accounts and the headless browser

`mcpShared.servers` registers OAuth MCP accounts in Claude and Codex under the
same names, and both clients use one authorization per account. Kiro keeps its
own registry.

```nix
mcpShared = {
  gateway = null; # on the credential host; "user@credential-host" everywhere else
  servers = {
    mail-private = { url = "https://mail.example/mcp"; callbackPort = 18872; };
    mail-work = { url = "https://mail.example/mcp"; callbackPort = 18873; };
  };
};
```

## How a client connects

Each server entry runs `flakelab-mcp connect <account>`. On the credential host
(`gateway = null`) that starts the pinned `mcp-remote` adapter against the
account's credential directory. Every other box runs `flakelab mcp connect
<account>` on the gateway through `ssh -T` with `BatchMode=yes`,
`ForwardAgent=no`, `ClearAllForwardings=yes` and a 10 s `ConnectTimeout`, and
speaks MCP over that stdio. SSH to the
gateway must work without a prompt, and the gateway must be reachable whenever
one of these servers is used. No MCP HTTP port is opened.

## Where the credentials live

Only on the credential host, one directory per account:
`~/.local/state/flakelab/mcp-auth/<account>/` (0700, files 0600). Two accounts
at the same URL still get separate directories. The adapter serializes token
refreshes across the processes that use the directory, so every client on every
box shares one refresh-token owner. The generated configuration in the Nix
store holds URLs, ports and the gateway name, never a token. Keep this directory
out of any synced folder: two copies of a rotating refresh token invalidate each
other.

`flakelab mcp status` prints, per account, whether credentials are stored
(`stored` or `login-required`). `stored` is what the adapter starts on without
a browser: an access token with no expiry or more than a minute left, or a
refresh token beside it. It does not ask the provider whether they are still
accepted. Run on a box with a gateway, it reports the gateway's store.
`connect` refuses a `login-required` account with the login hint rather than
start an adapter that would wait out its five-minute auth timeout.

## Logging in

Run `flakelab mcp login [account…]` on a box with a desktop browser (a WSL box
opens the Windows browser). Each account's login runs on the credential host
over SSH, with that account's `callbackPort` forwarded on loopback only. The
browser opens the provider's authorization page and its callback travels back
through the forward, so there is no URL to copy out of SSH or tmux. A login
fails if the callback port is already taken on either side.

Refreshes need no interaction. After a provider revokes a grant, run
`flakelab mcp login --fresh <account>`: it deletes that account's tokens and
client registration and registers again.

## Moving existing Codex grants

Without this step every account needs one `flakelab mcp login`. With Codex's
file credential store (`~/.codex/.credentials.json`), the grants Codex already
holds on the credential host can be moved instead. This is an operator step,
run once on the credential host:

1. Stop every Codex process on that host that uses those servers.
2. Switch the host to the configuration that declares `mcpShared.servers`.
3. Run `flakelab mcp import-codex`.
4. Start the clients again.

The import needs exactly one Codex entry per declared account, matched on both
the server name and the URL, and refuses to run if an account's credential
directory already exists. It writes a rollback copy of the whole Codex file
beside it (`.credentials.json.before-shared-mcp`, 0600), moves the tokens and
the Codex client id into the account directories, and removes the moved entries
from Codex's file. Never restore that copy while the shared adapter is in use:
the refresh token has one owner. Grants Codex keeps only in the OS keyring
cannot be moved; those accounts need a login.

An imported account keeps using the Codex client id. If its refresh fails, the
provider may reject a new authorization for that client at the adapter's
callback address; `--fresh` replaces the registration.

## Headless browser

`mcpBrowsers.headless = true` registers `playwright-headless` in Claude and
Codex on any target. Its tools are `mcp__playwright-headless__browser_*` in
Claude. It runs Playwright's own MCP server from nixpkgs' `playwright-driver`
with that build's Chromium headless shell. Each server process gets a fresh
in-memory profile, so parallel sessions share no cookies or storage and never
lock a profile directory. The Chromium sandbox stays on.

The server and the browser come from one package: `@playwright/mcp` on npm is
a thin wrapper around an alpha `playwright-core` that no nixpkgs browser build
matches, while nixpkgs' `playwright-core` carries the same MCP server and names
the headless-shell revision its browsers were built for. A nixpkgs update moves
both together. The launcher links only the headless shell, the same store path
the full browser set in `.zshenv` (`PLAYWRIGHT_BROWSERS_PATH`) already
references, so the server adds only `playwright-core` and the Node.js build it
was packaged with.

The Windows Chrome bridge is separate and unchanged: the `mcp-playwright`
Claude plugin, whatever Playwright server a `codexMcpSources` manifest gives
Codex, and Kiro's `mcpPlaywright`. The
headless server drops every `PLAYWRIGHT_MCP_*` variable it inherits, because
the bridge's extension settings reach all servers through the clients'
environment. Snapshots and screenshots land in `.playwright-mcp/` under the
session's working directory, as with the bridge.
