## Permissions and auto mode

Reference: <https://code.claude.com/docs/en/auto-mode-config.md>. The tier order this flake writes is in AUTO-MODE.md.

`permissions.deny` and `permissions.ask` are both evaluated before the classifier and neither can be cleared by it: a deny rule never prompts, an ask rule always prompts. Destructive-but-legitimate work therefore belongs in `autoMode.soft_deny`, which a message naming the operation and its target clears — putting it in `deny` or `ask` revokes that.
