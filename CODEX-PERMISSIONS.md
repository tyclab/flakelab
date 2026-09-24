# Codex permissions

Enable `flakelab.codexAutoReview` and `flakelab.codexEnforcePermissions` in the
private overlay. Flakelab generates defaults in `/etc/codex/config.toml`, enforced
controls in `/etc/codex/requirements.toml`, and command rules in
`~/.codex/rules/flakelab.rules`. The user config stays writable for trust and UI
settings. Claude configuration is independent; no Claude hooks, agents or
skills are needed.

## Permission layers

| Action                                                                      | Codex mechanism                                                                |
| --------------------------------------------------------------------------- | ------------------------------------------------------------------------------ |
| Read ordinary files; edit the current workspace and temporary files         | `permissions.flakelab`, extending `:workspace`                                 |
| Edit protected workspace control directories or files outside the workspace | Sandbox denial; a requested escalation goes to automatic review                |
| Run a command requiring network access                                      | Network disabled in the profile; requested escalation goes to automatic review |
| Run a matching sensitive command, even inside the workspace                 | A `prompt` command rule routes it to automatic review                          |
| Call a reviewed, explicitly listed MCP read tool                            | Exact tool name with `approval_mode = "approve"`                               |
| Call another MCP tool or a Codex app tool                                   | `prompt` by default, with `approvals_reviewer = "auto_review"`                 |
| Decide whether a requested escalation fits the user's authorization         | Native reviewer policy, supplemented by the private overlay                    |

`approval_policy = "on-request"` lets the agent request escalation; it does not
mean every request needs a human click. The automatic reviewer evaluates the
actual action, user authorization and available tool evidence. A denied request
does not authorize switching tools or changing permissions to bypass it. A user
can explicitly approve the pending action through Codex's `/approve` flow.

Command rules match argument prefixes. They do not classify arbitrary shell
programs, aliases or scripts. No broad `allow` rule is installed: an `allow`
rule can grant execution outside the sandbox. A `prompt` decision alone does not
skip the sandbox on the first attempt in Codex 0.156.1. The sensitive prefixes complement
the sandbox and reviewer; they do not reproduce Claude's classify-all-shell
mode. Mirror-push prefixes are forbidden.

## Private overlay

Keep account names, exact MCP grants and environment-specific authorization in
the private overlay. A minimal example:

```nix
flakelab = {
  installCodex = true;
  codexAutoReview = true;
  codexEnforcePermissions = true;
  codexMcpSources = [ ./mcp.json ];
  codexReadOnlyTools.example = [ "search" "get_item" ];
  codexSettings.permissions.flakelab.filesystem = {
    "~/.config" = "read";
    "~/.local" = "read";
  };
};
```

Protect control directories explicitly if sessions may start in the home
directory. Start normal coding sessions inside the relevant repository: a
workspace rooted at home otherwise grants broad writes there. Read-only rules
protect contents from sandboxed writes; they do not prevent reading credentials.

Codex 0.156.1 preserves read-deny restrictions even during escalation. Adding a
`deny` path therefore prevents ordinary unsandboxed retries, including network
and authentication workflows. This setup uses read-only control directories and
scoped reviewer authorization. It does not claim to intercept every credential
read. Do not add read-deny rules without testing the complete escalation workflow.
Protecting a symlink under a writable root can also make sandbox startup fail.

Filesystem profiles constrain local command execution, not remote MCP servers,
Codex app tools, inherited environment values or the client's own authentication.
Credential handling still follows the reviewer policy and task instructions.
Keep credential values out of tool output.

Audit each MCP grant against the live tool's behavior and schema. A tool's
`readOnlyHint` is evidence, not sufficient authorization: a tool that prepares a
delete or send still needs review. Unlisted and newly introduced tools default
to review. Installing an MCP server does not authorize every operation it exposes.

Setting `auto_review.policy` **replaces** Codex's default policy. If using a
private supplement, prepend the complete upstream policy from a fixed commit
with a fixed Nix hash, then append the supplement. Recheck that baseline when
upgrading Codex. Keep repository CI, branch protections and the human merge
requirement for permission-policy changes in force.

With `codexEnforcePermissions`, Nix puts the selected profile, approval mode,
reviewer, complete reviewer policy (`guardian_policy_config`) and command rules
in native managed requirements. User and project configuration cannot weaken
those controls. Only the managed `flakelab` and built-in `:read-only` profiles are
selectable. The same Nix rule list generates both requirements and local Starlark;
managed rules cannot grant unreviewed execution.

MCP and app per-tool approval modes remain configuration defaults: Codex has no
equivalent managed per-tool approval setting. Service token scopes and service
permissions remain separate controls. The writable user file can still hold
trust decisions and UI preferences.

Without `codexEnforcePermissions`, all these settings remain overridable defaults.
Remove legacy `sandbox_mode` and `sandbox_workspace_write` keys before migration;
the Nix module rejects them in `codexSettings` when automatic review is enabled.

## Verification

1. Run `nix build --no-link .#checks.x86_64-linux.codex-config`.
2. Check rule decisions without executing the commands:
   `codex execpolicy check --rules ~/.codex/rules/flakelab.rules -- git push origin main`.
3. Apply the overlay with `flakelab update`, then run `flakelab doctor` and
   `codex doctor --summary --no-color`.
4. In a new Codex session, confirm the `flakelab` profile and automatic reviewer.
   Use `codex sandbox --include-managed-config -P flakelab -C <workspace> -- <command>` with synthetic
   files to check allowed edits, protected directories and network
   restrictions. Never test by printing real credentials.
5. Inspect the live MCP inventory and confirm that exact read grants match it.

Validated against Codex 0.156.1 on NixOS/WSL. Permission profiles are currently
beta; validate runtime behavior as well as generated TOML after upgrades.

Official references: [permission profiles](https://learn.chatgpt.com/docs/permissions),
[automatic review](https://learn.chatgpt.com/docs/sandboxing/auto-review),
[command rules](https://learn.chatgpt.com/docs/agent-configuration/rules),
[configuration](https://learn.chatgpt.com/docs/config-file/config-reference).
Managed controls: [requirements](https://learn.chatgpt.com/docs/enterprise/managed-configuration).
