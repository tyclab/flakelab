# Agent clients, memory and dialog probes

Read for this topic; paths below are relative to the repository root unless stated otherwise.

- Claude Code keys transcripts by working directory
  (`~/.claude/projects/<slug>`, the path with `/` as `-`), and auto-memory too
  unless `claudeAutoMemoryDirectory` names one store: renaming or moving a
  checkout orphans them. Move the slug directory on this box, in the state root
  (under the backup lock) and on every other box.
- Client dialog behaviour (Claude Code, Codex) is probed by driving the TUI in
  an isolated tmux server (`tmux -L spike`) and reading `capture-pane -p`, with a
  stdio MCP server that logs every line as the probe. Pause about a second
  between `send-keys -l <text>` and `Enter`: both TUIs drop an Enter sent in the
  same instant.

## Nested instructions

Verified documentation for the installed Claude Code 2.1.310 and Codex 0.164.0:
Claude Code's [AGENTS.md support](https://code.claude.com/docs/en/memory#when-claude-code-reads-agentsmd)
loads ancestor instructions at startup and nested instructions when its Read tool
opens files there, subject to its CLAUDE.md precedence and Project instructions setting.
Codex's [discovery chain](https://learn.chatgpt.com/docs/agent-configuration/agents-md)
runs from the repository root to the session working directory at startup.
These are different triggers; a root-started session is not proof that every area
file was loaded. This repository uses explicit topic links instead of relying on
identical automatic loading. Plain Markdown links keep runbooks on demand;
`@` imports would load their full text.
