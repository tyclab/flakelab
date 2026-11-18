## Permissions and auto mode

Do not add `permissions.deny` or `permissions.ask`: neither is clearable by the
classifier. Put destructive but legitimate work in `autoMode.soft_deny`; read
AUTO-MODE.md.

The operator clears a classifier denial by naming the action. Ask at once, in
the same turn, with the native AskUserQuestion dialog: name the exact action and
its target; an `ask_question` answer does not clear it. After the yes, run the
same action. Never retry it unchanged, reach its effect by another route or hand
it back as the operator's work. A subagent stops and returns the denied command
to its caller, which asks.
