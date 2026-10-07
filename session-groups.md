# Claude session groups and handover

Fable and Opus/other are independent tycswap rotation groups. Every session in a
group uses the same stable profile and active account; switching that group
changes the account used by its sessions on subsequent requests. The other
group and existing unmanaged sessions retain their own ownership.

Choose a group for new work:

```sh
flakelab sessions --start claude --group fable /path/to/work
flakelab sessions --start claude --group opus /path/to/other-work -- --model opus
flakelab sessions --attach claude-work
```

`--detach` starts the tmux window without attaching. The same launch can run
without tmux as `tycswap run --group fable --` in a terminal. A group may refuse
an account that another group, the default login, or a legacy session already
owns. Ownership and account compatibility are separate from available quota.

Inspect groups and select an account for one group:

```sh
tycswap groups --json
tycswap groups switch fable ACCOUNT
tycswap groups switch opus ACCOUNT
```

`ACCOUNT` is an account selector from tycswap's roster. Each switch checks
ownership and compatibility. The Fable command moves every session in Fable
together; Opus/other remains independent. To choose an initial account in a
terminal, use `tycswap run --group fable ACCOUNT -- --model fable`.

The Fable group uses Fable; Opus/other uses a compatible non-Fable model. Fable
quota exhaustion does not by itself exhaust Opus quota. Shared weekly and
five-hour windows still matter for both. In the dashboard, choose the group
above the accounts, then click Weekly, 5-hour or Fable to sort; click again to
reverse. Next best restores availability ordering. Sorting changes the display
without changing automatic rotation policy.

Fable startup and continuation are separate capabilities. Start on a
compatible Max account. If you have verified that a Business account can
continue Fable, record that specific capability before switching the group:

```sh
tycswap groups capability ACCOUNT continue true
tycswap groups switch fable ACCOUNT
```

Record `continue true` only after verifying the entitlement with that account;
it does not grant startup access. A quota bar is not proof of either capability.
Pro accounts remain excluded. Unknown compatibility holds rotation rather than
silently changing models.

Each group has its own rotation settings and cooldowns. For example:

```sh
tycswap groups config fable autoswitch.fiveHourThreshold 90
tycswap groups config opus autoswitch.strategy best
tycswap groups reconcile fable
```

Use `reconcile` when group status reports pending or uncertain ownership after
an interrupted switch; inspect `tycswap groups --json` again afterward. Model
limits follow the group's live sessions, so `groups config ... autoswitch.model`
is refused. Choose another group by restarting or resuming the conversation.

Leave existing sessions running until you choose to restart them. To move an
old conversation, save its session list, stop the selected session normally,
and select its target group on resume:

```sh
flakelab sessions --save /tmp/before-restart.txt
flakelab sessions --resume /tmp/before-restart.txt --group fable
```

`--resume` prints one command per session; run the selected command in its own
terminal. A snapshot can contain several sessions: `--group` applies to every
Claude line printed, while Codex lines keep their own command. To select just
one conversation directly:

```sh
cd /path/to/work
tycswap run --group fable --resume ORIGINAL_ID
# An explicit transcript path resolves an ambiguous conversation id:
tycswap run --group opus --resume /path/to/profile/projects/slug/ORIGINAL_ID.jsonl
```

Tycswap uses Claude's native fork when moving across profiles, preserves the
original transcript and records the new conversation id. Subsequent resumes
use the group's actual continuation id. Avoid running both copies as editors
of the same workspace. A compatible model stays in its group; to change from
Fable to Opus/other, stop and resume into the other group explicitly.

When a captured stopped turn reaches a corroborated account limit, tycswap
first tries another compatible account. If none is expected to be usable
within 30 minutes and the other provider can run, the recovery card offers
Continue in Codex/Claude or Wait. To use a 15-minute threshold instead:

```sh
tycswap config set autoswitch.handoverWaitMinutes 15
```

Wait dismisses the handover offer for that incident while keeping the source
conversation and normal account recovery. Stale quota, uncertain ownership or
unknown resets remain unknown. Network errors, provider overload and a manual
stop alone do not trigger an exhausted-quota offer. If the destination is also
blocked, the card shows the blocker instead of offering an unusable session.

Continue in the other tool is a review workflow:

1. Choose the session action or recovery card, then supply the objective and
   any constraints or next steps.
2. Review the saved context and omissions. It uses recent messages, saved
   notes and available workspace/branch changes without asking the exhausted
   source model to summarize. Check for sensitive content and missing details;
   credential files, attachments, permissions and approvals do not carry over.
3. Confirm the source is idle, with no pending tools, approvals, commands or
   background edits. For a Claude destination, choose Fable or Opus/other.
   Select Start continuation only after that review.

An unmanaged live source must exit before the destination starts. Background
commands must also finish; exiting a terminal is not proof that they stopped.
A managed Claude source may stay open while idle, but its editing prompts are
paused for that workspace once the destination is reserved. The original
conversation remains available. The destination starts a new conversation
with its own permissions, and its actual session id confirms the transfer.
If confirmation is pending, the workspace stays reserved; do not start a
second continuation.

Flakelab launches the reviewed destination in tmux. If that launcher or its
group support is unavailable, the dashboard shows the reviewed terminal plan.
Stop the source before using that manual fallback; it does not reserve editing
ownership automatically. Preparing or reviewing context alone never starts a
new session. To return
editing ownership to the managed source, stop the destination, verify that no
background work remains, then reclaim the workspace:

```sh
tycswap recovery reclaim --cwd /path/to/work --confirm-no-background-tools
```

Automatic limit capture is installed through lifecycle hooks for managed
Claude sessions launched in a group. Existing unmanaged sessions gain those
hooks when you choose to restart them through the group launcher. An idle
Claude session can also be selected manually in the session list, subject to
the same review and source-exit rules.

Automatic Codex capture requires a typed app-server stream observed by its
owning host, bound to the actual source process and account. Ordinary
unmanaged Codex TUI error text and rendered rollout errors do not provide that
capture. After the source exits and all background work ends, its explicitly
selected saved transcript can still prepare a manual context handover:

```sh
tycswap recovery prepare --provider codex --session SOURCE_ID --cwd /path/to/work \
  --transcript /path/to/rollout.jsonl --objective 'Continue the selected task'
```

This prints a packet for review; it does not launch a destination. Review it
and its omissions before explicitly starting another conversation with the
selected context. An observed Codex source must also exit before automatic
handover launch, because passive observation cannot prevent another turn.

Save managed sessions and recover them without specifying a new group:

```sh
flakelab sessions --save
flakelab sessions --resume
flakelab sessions --open  # Windows Terminal tabs in WSL
flakelab sessions --recent
flakelab sessions --json
```

The table shows each live session's group. JSON includes its profile path but
no credential contents. Discovery reads registries and transcripts from
`~/.claude`, legacy tycswap account profiles, and
`$XDG_DATA_HOME/tycswap/groups/{fable,opus}/profile` (default data directory:
`~/.local/share`). The profile's registry supplies the actual migrated id;
the source id is not substituted into recovery snapshots. Recent stopped
group sessions print a command that resumes in their own group.

Profile sessions are saved as JSON lines containing `tool`, `cwd`, `session`,
`group` and `profile`. Unmanaged sessions keep `tool  directory  id` lines.
Snapshots written before the tool column, as `directory  id`, still mean
Claude. Without `--group`, an old unmanaged snapshot keeps its original resume
behavior. Saved legacy profiles resume with their own `CLAUDE_CONFIG_DIR`.
Autosaves use the same formats and keep one snapshot per boot; their default
selection remains restricted to this machine.

Group profiles and their conversation histories remain local. Flakelab's
existing cross-machine backup and transcript sync do not include them; these
snapshots support recovery on the same machine and do not copy group history
to another machine.

Flakelab's existing autoswitch timer calls `tycswap auto --once`; tycswap owns
group account selection, independent cooldowns, profile hooks and migrations.
The session launcher requires a tycswap release that supports `run --group`.
