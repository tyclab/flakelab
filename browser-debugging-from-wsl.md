# Browser Debugging from WSL

How to use Chrome's DevTools Protocol (CDP) from within WSL.

## Prerequisites

- Google Chrome installed on Windows
- Chrome path: `/mnt/c/Program Files/Google/Chrome/Application/chrome.exe`

## WSL2 NAT architecture

WSL2 NAT mode creates **two separate network namespaces** with independent loopback addresses:

```
Windows:  127.0.0.1  ← Chrome binds here
WSL:      127.0.0.1  ← WSL's own loopback (NOT the same as Windows)
```

- **Windows→WSL** auto-forwards (why OAuth callbacks and `localhost:3000` dev servers work)
- **WSL→Windows does NOT forward** — connecting to `127.0.0.1` from WSL reaches WSL's loopback, not Windows'

[Microsoft networking docs](https://learn.microsoft.com/en-us/windows/wsl/networking) confirm this is by design. Chrome ignores `--remote-debugging-address=0.0.0.0` — it hardcodes the bind to `127.0.0.1`.

### Verified test results (2026-04-16, port 9222, clean test distro)

| Check                         | Result                        |
| ----------------------------- | ----------------------------- |
| Windows curl `127.0.0.1:9222` | **PASS**                      |
| WSL nc `127.0.0.1:9222`       | **FAIL** — Connection refused |
| WSL nc `[::1]:9222`           | **FAIL** — Connection refused |
| WSL curl `127.0.0.1:9222`     | **FAIL** — timeout            |
| WSL curl `[::1]:9222`         | **FAIL** — timeout            |
| WSL Node.js fetch             | **FAIL** — fetch failed       |

Same results from both the clean test distro and the main distro. No portproxy was active. Firewall rule "Chrome Remote Debug" (port 9222 inbound allow) was present but irrelevant — the connection never leaves WSL's namespace.

## Chrome singleton behavior

Chrome enforces **one process per `--user-data-dir`**. Launching a second instance with the same `--user-data-dir` silently hands off to the existing process — `--remote-debugging-port` is **dropped** without error. CDP never starts.

Since Chrome 136+ (2025), `--user-data-dir` pointing to a custom directory is **required** for `--remote-debugging-port` to work at all.

**Stale profile directories are a trap:** if a previous session left `C:\Temp\playwright-chrome` with Chrome still holding a lock (background "green mode"), the next launch defers to it without CDP. Always kill all Chrome processes and verify count=0 before testing.

```bash
# Kill ALL Chrome (including background/green mode)
powershell.exe -Command "Get-Process chrome -ErrorAction SilentlyContinue | Stop-Process -Force"
sleep 3
powershell.exe -Command "(Get-Process chrome -ErrorAction SilentlyContinue | Measure-Object).Count"
# Must be 0
```

Sources: [Chrome DevTools blog](https://developer.chrome.com/blog/remote-debugging-port), [CEF singleton issue](https://github.com/chromiumembedded/cef/issues/3609)

## Launch Chrome with Remote Debugging

```bash
"/mnt/c/Program Files/Google/Chrome/Application/chrome.exe" \
  --remote-debugging-port=9222 \
  --user-data-dir="C:\\Temp\\chrome-debug" \
  --disable-search-engine-choice-screen \
  --guest \
  "http://localhost:3000" &
```

## Key Gotchas

### `--user-data-dir` is mandatory

Chrome **silently ignores** `--remote-debugging-port` when launched with the default profile. You must specify a separate data directory:

```
--user-data-dir="C:\\Temp\\chrome-debug"
```

### `--guest` alone is not enough

Guest mode does not imply a non-default data directory. Without `--user-data-dir`, remote debugging won't start.

### "Choose search engine" prompt blocks the page

The separate data dir creates a fresh profile. Chrome (v127+, EU/EEA) shows a search engine choice screen that blocks interaction until dismissed. The `--disable-search-engine-choice-screen` flag suppresses it — already included in the launch command above.

### Reaching CDP from WSL

Since WSL can't reach Windows `127.0.0.1` directly (see architecture above), use PowerShell (runs as a Windows process, same namespace):

```bash
powershell.exe -Command "Invoke-WebRequest -Uri http://localhost:9222/json"
```

### NTFS ownership across WSL distros

`wsl.conf` `metadata` mount option stores Linux UIDs on NTFS. If a Chrome profile dir was created by one WSL distro (UID 1000) and another distro has a different UID for the same username, Chrome may hit permission errors. Clean stale profile dirs when switching distros.

### Playwright MCP setup

Playwright MCP is provisioned via the pinned `mcp-playwright` Claude plugin
(pin set = `claudePlugins` in the `flakelab-config` overlay; `nix/home/claude.nix`
only implements the install). It runs in **extension mode**: the
[Playwright MCP Bridge](https://chromewebstore.google.com/detail/playwright-mcp-bridge/mmlmfjhmonkocbjadbfplnigmagldckm)
Chrome extension drives the already-running Windows Chrome over a WebSocket.
Since Windows→WSL localhost auto-forwards, no admin, portproxy, or firewall
rules are needed, and existing Chrome sessions (including OAuth logins) are
reused. Extension mode still resolves a Chrome binary to open the extension's
connect URL, and WSL has no Linux Chrome, so the Windows path must be supplied:
`nix/home/mcp.nix` passes `--executable-path` and `--browser chrome` into
`~/.kiro/settings/mcp.json`, and `nix/home/claude.nix` writes the equivalent
`PLAYWRIGHT_MCP_EXECUTABLE_PATH` / `_EXTENSION` / `_BROWSER` env vars into
`~/.claude/settings.json` for the plugin. Without either, the server throws
`"chrome" executable not found` before the extension can attach.

The extension auto-updates from the Chrome Web Store and cannot be pinned, so
the server has to keep pace with it — a server behind the extension's bridge
protocol is rejected with "The client uses an unsupported protocol version".
Two pins feed this host: `playwrightMcpVersion` in `nix/home/mcp.nix` (kiro) and
the pin inside the `mcp-playwright` plugin's `.mcp.json` (Claude), which
reaches the host only when a rebuild updates the installed plugin. Renovate
raises both; a host that has not rebuilt since the bump gets the error.

**Prerequisite:** install the [Playwright MCP Bridge](https://chromewebstore.google.com/detail/playwright-mcp-bridge/mmlmfjhmonkocbjadbfplnigmagldckm)
extension in Chrome.

### Taking screenshots via CDP

1. Connect to the WebSocket endpoint from PowerShell
2. Send `Page.captureScreenshot`
3. Save the result to a Windows path (e.g. `C:\Temp\screenshot.png`)
4. Copy into WSL: `cp /mnt/c/Temp/screenshot.png /tmp/`

## Safety

**Never kill Chrome without asking** — the user may have important tabs open in other windows.
