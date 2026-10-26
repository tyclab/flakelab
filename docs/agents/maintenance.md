# Maintenance policy

Read for this topic; paths below are relative to the repository root unless stated otherwise.

Keep one repository instruction entry point, AGENTS.md, with linked topic
runbooks. Client configuration templates are application inputs.

- Comments in each code/configuration file stay at or below 20% of nonblank
  lines: a ceiling, not a target. Count documentation strings when they are
  explanatory comments. Identify comments with the language parser, keeping
  embedded scripts and data intact. Never add blanks or move prose inline to
  meet the ratio. Keep concise reasons, units, invariants and failure handling.
- README and agent guidance are exempt. Also excluded: byte-identical vendored
  third-party code/build output, Hugo site functional files, translations,
  example/template schema comments, files with fewer than ten code lines, and
  approved runtime text such as MCP tool descriptions. Our own generated output
  stays in scope: fix its generator.
- Preserve licenses, tool/compiler directives and runtime descriptions. Only the
  operator can grant a documented file-specific exception with path, reason and
  scope; report conflicts rather than deleting required content.
- Remove unused code/files/features only after checking callers, packaging and
  behavior. Run relevant checks, preserve supported workflows and avoid speculative
  features. Keep README commands and process diagrams consistent with code.
- Refine synced config comments with substantive changes unless the operator
  explicitly requests a comment-only rollout.
