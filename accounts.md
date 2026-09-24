# Accounts

A design for `flakelab accounts`: several logins per agent CLI on one box, for
the three this flake installs (Claude Code, Codex, Kiro CLI). One login per
tool is live at a time, switched by hand or, where the tool exposes its rate
limits, by a timer before the live one hits them, and any stored login is
runnable in a second terminal beside the live one. Proposal, not implemented;
the backlog entry points here.

## The problem

Each subscription is rate-limited on its own clock: Claude over a rolling
five hours, a rolling week and a weekly window per model on the plans that
have one; Codex over a five-hour and a weekly window, with per-model buckets;
Kiro over a monthly credit allowance. Each CLI holds exactly one login. With
two subscriptions for one tool the only way from one to the other is a logout,
a login, a browser round trip, and a lost turn for whatever agent was running.
Nothing shows how much of a window is left before that happens, and the three
tools keep their logins in three unrelated places, so every switch is a
different manual procedure.

What we want is small and specific:

| want                                                           | why                                                               | phase |
| -------------------------------------------------------------- | ----------------------------------------------------------------- | ----- |
| store a login, list the stored ones, per tool                  | the roster; every other command names an entry of it              | 1     |
| switch the live login of a tool without a logout               | seconds instead of minutes; where the tool allows, no restart     | 1     |
| show each account's headroom on every window the tool reports  | pick the right account before starting, not after the wall        | 2     |
| switch automatically before the limit, where usage is readable | the wall lands mid-task with no chance to react; a timer can act  | 3     |
| run a second account of a tool in its own terminal             | two long agent runs on two subscriptions at once                  | 4     |
| the active account and its headroom for the statusline         | know which account a session is spending, at a glance             | 2     |
| carried by `flakelab backup`, checked by `doctor`              | the roster is a credential set; it gets the same care as the rest | 5     |

## Prior art, and what is taken from it

For Claude Code the idea is
[claude-swap](https://github.com/realiti4/claude-swap) (Python, MIT) and its Go
port cswap (MIT). A downstream fork of cswap was audited feature by feature for
this design; the cut list below is that audit's outcome. For Codex,
[codexctl](https://github.com/Sawmills/codexctl) (Rust) does the same job with
a per-alias `CODEX_HOME` in which only `auth.json` is private and everything
else is a symlink, which is the profile shape this design uses for every tool.
Nothing is ported from any of them: the store is written fresh, in this repo's
shape. What the audits contribute is a set of facts and four conclusions.

The facts are external contracts, not code. Per tool:

**Claude Code.** `~/.claude/.credentials.json` holds
`{"claudeAiOauth": {accessToken, refreshToken, expiresAt (epoch ms), scopes}}`;
`~/.claude.json` holds `oauthAccount` (`emailAddress`, `accountUuid`,
`organizationUuid`, `organizationName`) beside everything else that file
carries; an API-key login is `primaryApiKey` in the same file, a different auth
axis. Its lock is a directory, `~/.claude.lock` for the credentials and
`~/.claude.json.lock` for the config, `mkdir` as the mutex, stale after ten
seconds of untouched mtime, the holder touching it every five, a waiter
retrying a few times with jittered one-to-two-second sleeps; a token refresh
reads, refreshes and saves under that lock and re-reads before saving, so a
credential swapped in under the lock makes the refresh stand down. The
endpoints the CLI itself uses: `POST
https://platform.claude.com/v1/oauth/token` with
`{grant_type: "refresh_token", refresh_token, client_id:
"9d1c250a-e61b-44d9-88ed-5944d1962f5e"}`, answering `access_token`,
`expires_in`, sometimes a rotated `refresh_token`; and `GET
https://api.anthropic.com/api/oauth/usage` with a bearer access token and
`anthropic-beta: oauth-2025-04-20`, answering `five_hour` and `seven_day`
(`utilization`, `resets_at`) plus a `limits[]` array whose model-scoped entries
carry `scope.model.display_name` and `percent`. That endpoint's rate limit on
non-first-party clients, measured 2026-07: about 28 to 30 requests per access
token per rolling hour, not a refilling bucket; a burst blocks the token for up
to an hour; `Retry-After: 0` means the trailing hour is spent, `Retry-After: N`
is a burst rule that counts down. `CLAUDE_CONFIG_DIR` moves the whole config
dir, and the docs name it as the way to hold a second login. The public docs
document no usage endpoint and no account switch, but the statusline command
receives, with every refresh, a `rate_limits` object for the live login
(`five_hour` and `seven_day`, each with `used_percentage` and `resets_at`),
so the active account's figures cost no request at all; only the inactive
accounts need the endpoint. Two hook events also name the wall as it lands:
a `Notification` of type `quota_auto_resume_fired` (Claude Code has decided
to wait for the window) and, in the transcript, the rate-limit error itself.

**Codex.** `~/.codex` is the home and `CODEX_HOME` moves it whole. The login
is `$CODEX_HOME/auth.json` when `cli_auth_credentials_store` is `file`, which
it is here (`flakelab backup` already carries it as the ChatGPT login):
`{"OPENAI_API_KEY": null, "tokens": {"id_token", "access_token",
"refresh_token", "account_id"}, "last_refresh"}`. The identity is in the
`id_token`'s claims: `email`, `chatgpt_account_id`, `chatgpt_plan_type`. The
CLI refreshes at `https://auth.openai.com/oauth/token` with its own client id
and rewrites the file; a fresh `codex login` on an account that already has a
live seat invalidates that seat's token server-side, so a login is done once
and a switch is a file copy that never contacts the server. Rate limits come
back on every response as a `RateLimitSnapshot`: `primary` and `secondary`
windows (`used_percent`, `window_minutes`, `resets_at` in epoch seconds), named
per-model buckets (`limit_id`, `limit_name`), `credits`, `plan_type`, and they
are readable on demand through the CLI's own JSON-RPC server,
`codex app-server`, method `account/rateLimits/read`, or with one HTTPS call
to `https://chatgpt.com/backend-api/wham/usage` with the bearer and a
`chatgpt-account-id` header, which is what codexctl does. `codex login status`
exits 0 when a credential is present. Sessions live under
`$CODEX_HOME/sessions/` and `codex resume <id>` reopens one.

**Kiro CLI.** `~/.kiro` holds agents, skills, steering, settings and sessions
and `KIRO_HOME` moves it. The login is elsewhere:
`~/.local/share/kiro-cli/data.sqlite3`, the SQLite store the CLI inherited
from the Amazon Q Developer CLI, table `auth_kv` (`key`, `value`): the row
`kirocli:odic:token` for a Builder ID or IAM Identity Center login (a JSON
`{access_token, expires_at, refresh_token, region, start_url, oauth_flow,
scopes}`; `kirocli:social:token` and `kirocli:external-idp:token` for the
other sign-in methods) and `kirocli:odic:device-registration`, the SSO-OIDC
client registration a refresh needs; beside them the `state` table holds
`api.codewhisperer.profile` (the profile ARN), `auth.idc.start-url` and
`auth.idc.region`. `start_url` tells a Builder ID login
(`https://view.awsapps.com/start`) from an IAM Identity Center one. The CLI
refreshes through SSO-OIDC `CreateToken` at
`https://oidc.<region>.amazonaws.com` itself; one open report says it keeps a
refreshed token in memory without writing it back, which a stored copy would
inherit as staleness. No variable moves the store (`KIRO_HOME` moves only
`~/.kiro`; `XDG_DATA_HOME` may, by inheritance from the Amazon Q code, and is
unverified). `kiro-cli login` takes `--license pro|free`,
`--identity-provider <start url>`, `--region`, `--use-device-flow` and
`--social google|github`; `kiro-cli logout` clears the rows;
`kiro-cli whoami --format json` prints the account type, email, region and
start URL (followed by a plain-text profile trailer, so the JSON has to be cut
out); `KIRO_API_KEY` authenticates a non-interactive run. The allowance is
monthly credits, and it is readable: the same `GetUsageLimits` call the CLI's
own `/usage` makes, `POST https://codewhisperer.<region>.amazonaws.com/` with
`X-Amz-Target: AmazonCodeWhispererService.GetUsageLimits`, the bearer from
the token row and `{"profileArn": …}` from the profile row, answering the
current usage, the cap, overage settings and `nextDateReset`; the call spends
no credits. Sessions are `~/.kiro/sessions/cli/<id>.json` (id, cwd, state)
with a `.lock` while a process owns one, reopened with `kiro-cli chat
--resume-id <id>`, `--resume` or `--resume-picker`.

The conclusions, each learned the hard way upstream:

1. **One bar per window.** A five-hour window is a rate limit that bursts: a
   fan-out of subagents takes it from 85 % to full between two polls. A weekly
   window is the budget and creeps. Judging both by one threshold either
   overshoots the burst or abandons the week early. One bar per window class,
   set by how fast it fills, and the costliest window that has crossed its bar
   decides.
2. **Order targets by earliest weekly reset**, not most headroom. Most-headroom
   piles work onto one account and leaves the one about to renew idle.
3. **An API key is not an account to rotate onto.** It changes how the tool
   authenticates, which a running session cannot pick up. It is a shell
   variable, and it stays out of the roster.
4. **Persist a rotated refresh token before anything else.** The grant consumed
   a generation; a successor not written to disk kills the lineage.

## What is deliberately not built

Everything below exists in the audited Claude Code tool and is left out here,
with the reason.

| left out                                                               | because                                                                                                                                                 |
| ---------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| a corporate LLM-gateway client, its SSO login, key minting, budget     | there is no gateway on this box; a proxy is `ANTHROPIC_BASE_URL` in a shell if it is ever wanted                                                        |
| a plugin-usage telemetry reporter and OTLP header helper               | nobody is collecting; flakelab's Claude settings turn reporting off, not on                                                                             |
| fleet-published "mandatory" `settings.json` keys fetched at start      | the flake is the fleet: `nix/home/claude.nix` asserts settings, reviewed, at every switch                                                               |
| a menu-bar / tray app, a browser dashboard, a full-screen TUI          | a WSL distro has no tray; one user does not need a web app; `flakelab accounts` in a terminal and the statusline cover the glance                       |
| self-update, release manifests, install bootstraps, signed binaries    | nix delivers the script; `flakelab update` is the update                                                                                                |
| macOS Keychain and Windows credential-store backends, console handling | the targets are `wsl` and `proxmox-vm`, both x86_64-linux, both file-based                                                                              |
| byte-compatibility with the Python tool's roster, cache, export, log   | nothing here has ever run it; a fresh schema needs no float-formatting shims or migrations                                                              |
| `export` / `import` files                                              | `flakelab backup` carries the store like it carries the Codex tokens, and `--restore` puts it back                                                      |
| numbered slots that move and swap, sparse and reusable                 | an id is assigned once and never reused; an alias is the name; there is nothing to move                                                                 |
| directory-to-account mappings                                          | `flakelab accounts env` in the shell that needs it; the audited tool had already removed the writer                                                     |
| API-key entries in the roster, and an automatic fallback onto one      | conclusion 3 above                                                                                                                                      |
| an eight-way classifier of the outgoing credential at switch time      | it guards slot reuse and recycled identities; ids here never recycle and the account id is recorded at add, so the rule is one comparison               |
| a settings store with its own `config get/set` command                 | thresholds are flake options with per-run flags, like every other knob in this repo                                                                     |
| a PTY wrapper that watches the tool's output for a limit message       | codexctl's spend-cap recovery; usage is read from the tool's own API instead, and a limit that only shows in the TUI is on the verify list, not scraped |

The audited fork's own additions are proprietary to its owner and are neither
needed nor consulted. The MIT projects may be read for the contracts above,
which are facts about the tools and their APIs rather than anyone's code.

## Design

### Principles

- **Linux, files, nothing else.** No keychain, no registry, no platform
  switch. A credential is a 0600 file or a row in the tool's own SQLite store;
  our lock is `flock`, and a tool's own lock protocol is honoured where one
  exists.
- **The tool's home is the tool's; the store is ours.** A live login is read
  and rewritten only inside one transaction, under the tool's locks where it
  has any. A live token is never refreshed by us: the tool owns it. Stored
  tokens of inactive accounts are ours to refresh only where the engine needs
  their usage, which today means Claude.
- **One roster, one adapter per tool.** The roster, the commands, the profile
  machinery, the engine and the tests are shared. Everything a tool does
  differently sits behind one contract (below), in one file per tool, so a
  fourth tool is a fourth file.
- **One decision function.** The auto-switch engine is a pure function from
  one JSON document (roster, usage cache, engine state, settings, now) to a
  decision, an event list and the next state. It does no I/O and does not know
  which tool it is deciding for, so its tests are fixtures through `jq`.
- **A hook never touches the network.** `status --json` for the statusline
  reads the cache and nothing else.
- **Carried by backup, never in the state root.** The store is a credential
  set: it rides the payload like `~/.codex/auth.json` does, 0700 and 0600, and
  the state root's rule that credentials never go there stands.
- **No prompts.** Every command is safe to run from an agent's shell; the one
  destructive verb, `remove`, takes `--yes` and refuses without a terminal
  otherwise, as `gitcleaner` does.

### The adapter contract

Each tool answers the same eight questions; the roster and the commands never
ask anything else. Where the answer is "no", the command that needs it says so
and stops rather than improvising.

| question                                 | Claude Code                                                                             | Codex                                                                                                                         | Kiro CLI                                                                           |
| ---------------------------------------- | --------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| identity of the live login               | `oauthAccount` in `~/.claude.json`: uuid, email, org                                    | `id_token` claims in `auth.json`: `chatgpt_account_id`, email, plan                                                           | the token row: `start_url`, region; the email from `kiro-cli whoami` if it has one |
| the credential to store                  | `.credentials.json` + the `oauthAccount` block                                          | `auth.json`, whole                                                                                                            | the two secret rows, exported as JSON                                              |
| a lock to hold while swapping            | the two `mkdir` locks                                                                   | none known: swap only while no `codex` runs, else refuse                                                                      | none known: swap only while no `kiro-cli` runs, else refuse                        |
| does a running session follow a switch   | yes on Linux, on its next message (verify 1)                                            | no: a new process; running ones keep their token (verify 6)                                                                   | no: a new process (verify 9)                                                       |
| usage, and how it is read                | the statusline's `rate_limits` for the live login; the endpoint for the rest            | `codex app-server` → `account/rateLimits/read` in the account's profile                                                       | `GetUsageLimits` with the stored token and profile ARN: one monthly window         |
| may we refresh an inactive stored token  | yes, and must persist first                                                             | no: the tool refreshes on first use after a switch                                                                            | no: same                                                                           |
| profile: the env var that moves the home | `CLAUDE_CONFIG_DIR`                                                                     | `CODEX_HOME`                                                                                                                  | `KIRO_HOME` for `~/.kiro`; the secret store needs its own move (verify 8)          |
| profile: what is shared by symlink       | settings, keybindings, `CLAUDE.md`, skills, commands, agents, projects, `history.jsonl` | `config.toml`, `*.config.toml`, `AGENTS*.md`, `hooks.json`, `hooks/`, `rules/`, `memories/`, `sessions/`, `.credentials.json` | agents, skills, steering, settings, sessions                                       |

Never shared, per tool: what carries the identity or is instance-scoped,
`.claude.json`, `.credentials.json`, `plugins/`, `sessions/`, `ide/` for
Claude Code; `auth.json`, `log/`, `packages/` and the SQLite state for Codex;
the secret store for Kiro.

### On disk

`~/.local/state/flakelab/accounts/`, mode 0700, beside the sessions saves and
the state-sync bookkeeping that already live under that root:

```
accounts.json            the roster
<id>/                    the stored login, files named by the adapter, 0600
usage.json               per-account usage, poll plan and failure backoff
auto.json                engine state: cooldown, unhealthy ticks, idle hold, quarantine
auto.log                 the engine's events, one JSON object per line, size-rotated
unclaimed/<ts>.json      a live credential the switch could not attribute (see below)
profiles/<id>/           a private home per account, for run / env
lock                     flock; every writer takes it first
```

`accounts.json`:

```json
{
  "version": 1,
  "active": { "claude": 2, "codex": 3, "kiro": null },
  "next": 4,
  "accounts": {
    "1": {
      "tool": "claude",
      "id": "acct-uuid…",
      "label": "a@example.com",
      "org": "personal",
      "alias": "home",
      "added": "2026-09-23T10:00:00Z"
    },
    "2": {
      "tool": "claude",
      "id": "acct-uuid…",
      "label": "b@example.com",
      "org": "Example GmbH",
      "disabled": false,
      "added": "…"
    },
    "3": {
      "tool": "codex",
      "id": "chatgpt-account-id…",
      "label": "b@example.com",
      "org": "plus",
      "added": "…"
    }
  }
}
```

An id is `next` at the time of `add` and is never handed out twice; `id` is
the tool's own identifier for the account (Claude's `accountUuid`, Codex's
`chatgpt_account_id`, Kiro's `start_url` plus region), the identity every later
comparison uses; `label` is what the listing shows. Every command that names an
account takes the id, the alias or the label, and the alias is unique across
tools so `switch work` is unambiguous.

### The commands

`flakelab accounts` is one script (`files/scripts/accounts`) with verbs,
because a dozen operations as flags is what the audited tool's legacy grammar
looked like and what it spent a release retiring. The router passes the
argument list through unchanged, so a verb costs the router nothing.

```
flakelab accounts                          the roster, grouped by tool, with cached headroom; --fetch refreshes, --json
flakelab accounts add <tool> [--alias N]   snapshot the tool's live login into the store
flakelab accounts switch ID                make a stored account its tool's live login
flakelab accounts switch --next <tool>     rotate in id order, skipping disabled and at-limit
flakelab accounts switch --soonest <tool>  the account whose weekly windows renew first (auto's order)
flakelab accounts switch --best <tool>     the account with the most weekly headroom
flakelab accounts alias ID NAME|--unset
flakelab accounts disable|enable ID        hold an account out of rotation (still switchable by hand)
flakelab accounts remove ID --yes
flakelab accounts run ID [-- ARGS]         the tool as ID in this terminal only
flakelab accounts env ID | --unset <tool>  eval-able export of the tool's home variable for this shell
flakelab accounts auto [--once] [--dry-run] [--json] [--tool T] [--five-hour N] [--seven-day N] [--model-week N]
flakelab accounts status [--json]          per tool: active account and cached headroom; cache only, for hooks
```

Exit codes follow the sibling scripts: 0, 1 for a failure, 2 for a refusal or
usage error. `--json` prints one document on stdout and every notice on
stderr, so a caller parses stdout alone.

### Adding a login

`add <tool>` asks the adapter for the live identity and credential. A login
that is an API key (Claude's `primaryApiKey`, Codex's `OPENAI_API_KEY` with no
tokens, Kiro's `KIRO_API_KEY`) is refused with the shell-variable hint
(conclusion 3). An `id` already in the roster for that tool is refreshed in
place: the credential is rewritten, a quarantine on it is lifted, the roster id
stays. Anything else takes `next`. Either way the entry becomes that tool's
`active`, since it is the live login.

For Codex this is also the only supported way to get a second account in: log
in with the tool, `add codex`, log out, log in as the next, `add codex`. A
second `codex login` on an account that is already stored invalidates the
stored seat, so the listing marks a Codex token that has stopped working as
`seat revoked` rather than retrying it.

### Switching

One transaction, under our `flock` and then whatever the adapter names:

1. Read the live credential and identity.
2. Attribute the outgoing login. Its `id` names a roster entry of that tool:
   write the live credential into that entry, because the tool may have
   rotated the refresh token since it was stored and the entry must hold the
   latest generation (conclusion 4). It names none: copy the credential to
   `unclaimed/` and warn, never overwrite an entry with a stranger's token and
   never lose a login.
3. Write the target's credential where the adapter says (temp file beside it,
   0600, rename; for Kiro two `UPDATE`s in one SQLite transaction), splice the
   identity where the tool keeps it beside other state (Claude's
   `oauthAccount`, leaving every other key of `~/.claude.json` as it was), set
   `active`.
4. On any failure restore what step 1 read, in reverse order, and report the
   rollback.

For Claude Code the adapter's locks are the two `mkdir` locks, taken in that
order with the tool's protocol (a lock whose mtime is older than ten seconds is
removed and retaken; retry every quarter to half second; give up after nine
seconds; touch our own every three while held); a timeout refuses with "Claude
Code is refreshing credentials, retry in a few seconds" and changes nothing.
Claude Code re-reads the credential file per request on Linux, so a running
session continues on the new account with its next message; the command says
so. Verify 1 checks that claim before anything relies on it, and the fallback
is already in the repo: print the `flakelab sessions --resume` lines for the
sessions that must restart.

Codex and Kiro have no lock we know of and no live pickup, so their adapters
refuse the swap while a process of the tool is running (the same registry
`flakelab sessions` reads for Claude, and the process table for the other two)
unless `--force` says the running ones may keep their old token, and the
command then prints the `codex resume <id>` or `kiro-cli chat --resume-id <id>`
lines for them.

A target that has a live `run` session gets a warning on a manual switch: the
same lineage in two homes means whichever refreshes first strands the other.
The engine never picks such a target.

### Usage

Only where an adapter can read it. Two adapters can:

**Claude Code** fetches per account with the account's own access token; the
active account's token is read from `~/.claude`, never refreshed by us. An
inactive account whose token is expired, or whose fetch answers 401, is
refreshed first, the result written to its entry before it is used, and a
400/401/403 whose body says `invalid_grant` or `invalid_client` marks the
lineage dead (quarantine, below). Any other failure is transient and backs
off. The poll budget is the measured limit, kept with a margin: at most one
request per three minutes per token on average. Per account the plan is 3
minutes for the active account and 5 for a candidate, halved (to a floor of 3,
or 1 for the active account within fifteen points of its bar and moving) when
the binding window moved a point since the last fetch, and stretched by half
toward 5 and 10 minutes when it did not. Never scheduled past the next window
reset plus a minute, because the cached figure is obsolete once the window
rolls; an account at its limit is scheduled exactly at the reset that frees
it. `Retry-After: 0` backs the token off five minutes, `Retry-After: N` is
honoured up to fifteen, and for an hour after any 429 the floor is six
minutes.

**Codex** asks the tool: `codex app-server` started with the account's
profile as `CODEX_HOME`, one `account/rateLimits/read` over stdio, then exit.
That is the tool's own call with the tool's own token, so it needs no
endpoint, no client id and no refresh of ours; the tool refreshes if it must
and rewrites the profile's `auth.json`, which the adapter copies back into the
store (conclusion 4 again, by way of the tool). The cadence is the same plan
as above with no 429 rule until one is observed. The active account's figure
is read the same way from a scratch profile seeded from `~/.codex/auth.json`,
never from `~/.codex` itself (verify 7).

**Kiro** asks `GetUsageLimits` with the stored token and the profile ARN
from the same store, one call per stored account, cached like the others.
The answer is one window of class `month` (the credits used against the cap,
resetting on `nextDateReset`); it never steers a switch, because a monthly
allowance that is out is out until the first of the month and a burst cannot
change that between two polls, but the listing shows it, which is what a
switch by hand needs.

For **Claude Code** the live login's figures do not come from the endpoint
at all: the statusline command gets `rate_limits` with every refresh, and
the statusline plugin writes them into the cache (phase 7). The endpoint,
with its budget, is for the inactive accounts only, which halves the requests
and removes the active token from the count entirely.

Normalised per account into `usage.json`, whatever the tool:

```json
{
  "2": {
    "fetchedAt": "…",
    "nextPollAt": "…",
    "intervalS": 180,
    "failures": 0,
    "lastError": null,
    "windows": [
      { "label": "5h", "class": "session", "pct": 62, "resetsAt": "…" },
      { "label": "7d", "class": "week", "pct": 91, "resetsAt": "…" },
      { "label": "Fable", "class": "model", "pct": 40, "resetsAt": "…" }
    ]
  }
}
```

Three classes, and the adapter says which window is which: for Claude `5h`
and `7d` plus the scoped windows; for Codex `primary` is `session`,
`secondary` is `week`, and the named buckets are `model`. Spend, credits and
pay-as-you-go figures are shown in the listing but never steer a switch. Which
`model` windows count is `flakelab.accounts.modelWindows`, default `["all"]`;
narrow it to a list of display names when a plan reports windows that should
not steer. A figure older than five minutes is unknown for decisions, never
"fine" and never "full".

`flakelab accounts` prints the cache and the age of each figure; `--fetch`
polls what is due first. `list` never bursts: one fetch per account at most,
and only for accounts whose plan is due.

### Auto-switch

The engine (`files/scripts/lib/accounts-auto.jq`) is one jq program over one
document and one tool, called by `auto`, which does the I/O around it, once
per tool that has a usage adapter: read the roster, cache and state; run the
program; fetch what it asked for; run it again on the fresh document; act on
the decision; write the state; log the events. Its rules, in order:

1. No active account for the tool, or an active login not in the roster:
   `no-action`, with the `add` hint.
2. Three bars, one per class, from the options or the flags: session **85**,
   week **97**, model week **95**. 100 on a bar means never move proactively on
   that window. The deciding axis is the costliest window at or over its bar:
   the week, then a model week, then the session window. Losing the week
   costs days across every model, a model week costs days for one model, the
   session window costs a wait.
3. Trigger: `proactive` when the deciding axis crossed its bar; `at-limit`
   when any counted window is at 100; `failover` after three consecutive
   ticks with the active account's usage unknown. The exception to counting
   unknowns is an idle hold: the active token is expired on disk and no
   session is using it, which is the tool idle rather than dead, held for up
   to thirty minutes before the count resumes.
4. A cooldown of five minutes since the last switch stops a `proactive`
   trigger and nothing else.
5. Candidates: every enabled, non-quarantined entry of the tool other than
   the active one that has no live `run` session, whose weekly budget (the
   week, or a counted model week) is not spent, and whose usage is known. For
   `proactive` a candidate must also land under the bar on the deciding axis
   and beat the active account there by ten points, so two accounts hovering
   at the line cannot ping-pong. `at-limit` and `failover` skip both gates:
   any account with room beats a blocked or dead one.
6. Order: earliest weekly reset first (`soonest-reset`, the default), or most
   weekly headroom (`best`). Under `soonest-reset` an account over its bar is
   still tried only after every account under it.
7. Freshen the first candidate where the adapter allows it (Claude): a token
   expiring within ten minutes is refreshed now and persisted first
   (conclusion 4). Dead lineage: quarantine it and take the next. Transient
   failure: take the next, and if none is left report an error rather than a
   wall. Where the adapter forbids it (Codex), a stored token past its expiry
   is not a candidate.
8. Switch, through the transaction above. For a tool without live pickup the
   switch under the engine is the same as by hand: refused while the tool
   runs, so the engine's real value there is the `at-limit` case between
   sessions, and the notice that says which account the next `codex` will be.
   Record `lastSwitchAt` and the target.

No candidate with known usage: `blocked`, and when every candidate is known
and spent, the earliest reset among them is the time to sleep until. A
candidate that merely failed the hysteresis gate keeps the normal cadence,
because the `at-limit` escape must not be missed.

Quarantine is per entry: the sha256 of its refresh token and the reason. It
lifts by itself when the entry's credential changes (a fresh `add`, a
rotation), so a re-login is the whole repair.

Every tick emits events, `poll`, `switch`, `no-switch` with its reason,
`quarantine`, `blocked`, `error`, each carrying the tool, as lines in
`auto.log` and, with `--json`, on stdout. `--once` runs one tick per tool and
exits 0 unless a tick itself errored; the outcome is in the event, not the
exit code, because the unit that runs it must not show failed for "nothing to
do". `--dry-run` decides and reports but never switches or writes state.

Claude Code has since grown a related feature of its own: a session that hits
its quota can wait and resume itself when the window resets (the
`quota_auto_resume_*` notification events). That is the right answer when
there is one account and time to spare; this engine is the answer when there
is a second account and the work should not wait. The two meet in a hook:
a `Notification` hook on `quota_auto_resume_fired` runs
`flakelab accounts auto --once --tool claude` at the moment the wall lands,
so the reactive case does not wait for the timer, and the timer keeps the
proactive case. Both go through the same engine and the same transaction.

The timer is `flakelab-accounts-autoswitch` in `nix/home/backup.nix`'s style:
`flakelab.accounts.autoSwitchInterval`, default `null` (off), runs
`flakelab accounts auto --once --json` every interval. Its state between
ticks is `auto.json`, which is why the unhealthy count and the idle hold are
persisted rather than kept in a process; there is no process. Two minutes is a
sensible interval: the poll plan, not the timer, decides who is fetched when,
so a short timer costs nothing against the budget.

### A second account in a second terminal

`run` and `env` give an account a home of its own, `profiles/<id>/`, and point
the tool at it with the adapter's variable. The live login is untouched; the
two run side by side.

The profile is seeded from the store with the adapter's credential files and
the identity the tool expects beside them (for Claude Code `.claude.json` with
the entry's `oauthAccount`, `hasCompletedOnboarding: true`, the theme from
`~/.claude.json`, and `mcpServers` mirrored from it, the one user-scoped key
that file holds). Everything in the adapter's shared list is a symlink into
the real home. History is shared by default and `--no-share-history` opts out,
the reverse of the audited tool, because on Linux two processes on one
`projects/` or `sessions/` directory is exactly what two plain sessions
already are, and it keeps every transcript where `flakelab sessions`, the
memory sync and the transcript sync look. A profile that already has its own
copy of a shared item keeps it; a manifest lists the links this command made,
and only those are ever removed.

A reused profile is validated the tool's way (`claude auth status --json`,
`codex login status`, `kiro-cli whoami`; ten-second timeout) and reseeded when
that fails. `run` scrubs the tool's auth-override variables from the
environment (`ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`,
`CLAUDE_CODE_OAUTH_TOKEN` and the two file-descriptor variants; `OPENAI_API_KEY`;
`KIRO_API_KEY`), then execs the tool with the arguments after `--`. `env`
prints the export and the matching `unset` lines, notices on stderr, for
`eval "$(flakelab accounts env work)"`; `env --unset <tool>` prints the one
`unset`. A live profile session is detected the way `flakelab sessions`
detects any session: the tool's session registry where it has one, the
process table otherwise.

### Statusline and doctor

`status --json` is one object per tool, `{ "active": {id, alias, label},
"windows": [...], "fetchedAt": "…" }`, from the cache, in well under the hook
budget, for the statusline plugin to render the account and its binding
window. `flakelab doctor` checks the store's modes, that each tool's `active`
names the entry whose `id` is the live one (drift means someone logged in by
hand: "run `flakelab accounts add <tool>`"), names quarantined entries and
revoked seats, and reports the timer.

### Options

```nix
flakelab.accounts = {
  autoSwitchInterval = null;          # systemd span; null schedules no timer
  autoSwitchTools    = [ "claude" ];  # which tools the timer decides for; codex once verify 6/7 pass
  sessionThreshold   = 85;            # the 5h window, Claude and Codex alike
  weekThreshold      = 97;
  modelThreshold     = 95;
  modelWindows       = [ "all" ];     # display names, or "all"
  strategy           = "soonest-reset";  # or "best"
};
```

Exported to the script as `FLAKELAB_ACCOUNTS_*` by its wrapper in
`nix/scripts.nix`, the way `FLAKELAB_STATE_ROOT` reaches `claude-sessions`;
the `auto` flags override per run.

### Implementation

zsh, `jq`, `curl`, `flock` and `sqlite3` (for the Kiro adapter), the toolset
of the twelve scripts already in `files/scripts/`, with a pinned PATH in the
wrapper and a dispatch entry in `nix/cli.nix`. One file per adapter under
`files/scripts/lib/accounts-<tool>.zsh`, each defining the same eight
functions; the main script never branches on the tool name. The engine is the
one piece with real logic and it lives in jq, fed a document and returning
one, so zsh does only reading, fetching, writing and locking. If the jq
program stops being readable, the fallback for that one file is Python on the
interpreter the flake ships, which pre-commit already ruff-checks; not Go,
which would add a build, a vendored hash and a toolchain to CI for a one-user
tool.

`test-accounts` joins `make test` and `checks.<system>`: a fake `HOME`, a
`curl` stub on PATH answering the token and usage URLs from canned files,
stubs for `claude`, `codex` and `kiro-cli` answering their status and
rate-limit calls, a throwaway SQLite secret store in the Kiro layout, a fake
proc tree through `FLAKELAB_PROC_ROOT` as `test-claude-sessions` already
does, and a frozen `FLAKELAB_NOW` so the engine's fixtures are deterministic.
The transaction is tested for the rollback path by making the second write
fail, per adapter. The engine's rules above are its fixture list, one document
per rule, run once with each tool's window labels.

Phases, each shippable on its own:

1. Store, the adapter contract with the Claude adapter, `add`, the roster
   listing, `switch ID`, `alias`, `disable`, `enable`, `remove`, the suite.
   Usable the day it lands.
2. Claude usage: fetch, refresh, cache, the poll budget; headroom in the
   listing; `status --json`; the strategy switches.
3. The engine, `auto --once`, the timer, quarantine.
4. Profiles: `run`, `env`.
5. The Codex adapter: `add`, `switch` with the running-process refusal,
   profiles, then usage through `app-server` and the engine behind
   `autoSwitchTools`.
6. The Kiro adapter: `add`, `switch` through the secret store, profiles once
   verify 8 says how; no usage until verify 10.
7. `flakelab backup` category, `doctor` checks, README and CHANGELOG, and the
   statusline plugin reading `status --json`.

## Verify before building

Items 1 to 5 are Claude Code, 6 and 7 Codex, 8 to 10 Kiro.

1. **A switched credential reaches a running session.** Switch under a
   running `claude`, send a message, watch the new account's 5h figure move.
   The transaction's post-switch line depends on it; the fallback is printing
   `flakelab sessions --resume` lines.
2. **The usage endpoint and its limit.** The response shape, the
   `anthropic-beta` value and the per-token budget were measured mid-2026 and
   are undocumented; a week of `auto.log` with zero 429s is the health check,
   and a 429 episode outlasting an hour means the budget needs revisiting.
3. **`claude auth status --json` fields** on the installed version:
   `loggedIn`, the auth-method key and its value for a claude.ai login, the
   email and org keys.
4. **The VS Code extension** shares `~/.claude`; confirm it follows a switch
   the way the CLI does, or say in the listing that it does not.
5. **Whether Claude Code has grown a native account switch** since this was
   written. The docs name `/login`, `/logout` and `CLAUDE_CONFIG_DIR` and
   nothing else; if that changes, the roster becomes a thin layer over it and
   the transaction goes.

6. **Whether a running `codex` follows a swapped `auth.json`**, at least on
   its next refresh. If it does, the running-process refusal relaxes to a
   warning.
7. **`codex app-server` from a scratch profile**: that `account/rateLimits/read`
   answers with a copied `auth.json` and nothing else, and what it costs in
   time, since the listing calls it per stored account. And whether a plain
   `codex login status --json` or the session log already carries the last
   `RateLimitSnapshot`, which would make the call unnecessary for the active
   account.

8. **What moves the secret store.** `KIRO_HOME` moves only `~/.kiro`; test
   whether `XDG_DATA_HOME` moves `~/.local/share/kiro-cli/` (the Amazon Q
   code resolves it through `dirs::data_local_dir`, which honours it). Without
   a way to move it, `run`/`env` for Kiro is a swap, not a profile.
9. **Whether a running `kiro-cli` re-reads the token row** after a swap, and
   whether it writes a refreshed token back (one report says it does not,
   the inherited code says it does). A stored copy that never receives the
   refreshed generation dies at the next expiry.
10. **`GetUsageLimits` from outside the CLI**: the request shape above is
    what two monitoring tools use; confirm the region routing for an EU
    profile (`q.eu-central-1.amazonaws.com` in one of them) and that the
    profile ARN in the `state` table is the one the token is entitled to.
