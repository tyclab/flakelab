# Auto mode and the permission tiers

## Order of evaluation

`permissions` is consulted first, the auto-mode classifier second. Inside
`permissions` the binary's precedence constant is `{deny: 3, ask: 2, allow: 1}`;
a `deny` match short-circuits everything after it.

| #   | Layer                                  | Written by                                                        | Operator can clear it           |
| --- | -------------------------------------- | ----------------------------------------------------------------- | ------------------------------- |
| 1   | `permissions.deny`                     | flakelab `claudeDeny` (union, minus `claudeDenyStale`)            | **No. No prompt is raised.**    |
| 2   | `permissions.ask`                      | claude-plugins `permissions/recommended-ask.json`                 | Yes                             |
| 3   | `permissions.allow`                    | claude-plugins `permissions/recommended-permissions.json` (union) | pre-approved                    |
| 4   | `autoMode.{allow,soft_deny,hard_deny}` | flakelab `claudeAutoMode` (asserted whole)                        | `soft_deny` yes, `hard_deny` no |

`autoMode.classifyAllShell = true` puts every shell command through layer 4,
which is what suspends layer 3 in auto mode — the basis of the 2026-09-01
ruling that allowlists `git push`, `glab mr merge`, `glab ci run` and
`gitcleaner`. That suspension does not reach layer 1.

## Why the floor is almost empty

Layer 1 is unreachable from every direction: the classifier never sees the call,
and no operator instruction clears it. It is strictly harder than
`autoMode.hard_deny`, so the invariant above `claudeAutoMode` in `nix/options.nix`
binds here first — destructive-but-legitimate work belongs in `soft_deny`.

Force-push is **not** in the floor. The forge already refuses it: `main` on both
GitHub and GitLab carries `allow_force_pushes: false` with admin enforcement, for
every clone, machine and token. A client-side glob in one `settings.json` adds no
protection the server does not already give, and costs the operator the ability
to authorise a rebase on a feature branch.

Between 2026-08-26 and 2026-09-09 that floor denied 62 commands. 56 were
`--force-with-lease` — the spelling that refuses to clobber a moved ref. Three
were plain `--force`.

## Globs match raw text

`*` matches inside the command string, including across `&&` and `|` and into
quoted arguments. A trailing `*` also matches empty, so `--force*` catches
`--force-with-lease`. Verified case: `Bash(git push * -f*)` denied

```
git push -u origin feat/… | tail -3 && gh pr create … --body '… `clean -f` …'
```

on the `-f` inside the PR body. Scoping a glob to a branch name does not make it
precise; it only moves which text triggers it. Prefer `soft_deny` prose.

## Live state

```sh
jq '.permissions | {allow:(.allow|length), ask:(.ask|length), deny, defaultMode}' ~/.claude/settings.json
jq '.autoMode | {classifyAllShell, allow, soft_deny, hard_deny}' ~/.claude/settings.json
claude auto-mode config   # from a plain shell, not inside a session
```

Layers 1 and 3 are unioned on every `flakelab update`, so a hand edit that adds
survives and one that removes is undone. Layer 4 is asserted whole. Retiring a
floor rule means listing it in `claudeDenyStale`, not deleting it — the union
alone would leave it on every box that already merged it. Fix rules in the flake,
never in the file.
