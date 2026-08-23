# Security Policy

## Reporting a vulnerability

Please report security issues privately rather than opening a public issue.

- Preferred: open a private GitHub security advisory on this repository
  (Security tab → "Report a vulnerability").
- Alternative: email <security@tyclab.ai>.

Please do not file a public issue for a suspected vulnerability until it has
been triaged.

## Scope and expectations

This is a personal framework, published as a traceable reference rather than
a supported product (see the README "About" section). There is no SLA and no
bug bounty. Reports are acknowledged on a best-effort basis, target within a
week.

## Credentials in the backup payload

`flakelab backup`'s payload holds this host's provisioning seed by design —
`secrets.env`, the SSH key, glab/kube/helm config — and must never be
committed to this repository or any git checkout. See the README sections
["Secrets"](README.md#secrets) and
["Shared state between machines"](README.md#shared-state-between-machines)
for what is gated, what is synced, and what stays local-only.

If you find secrets committed to this repository's history, report it the
same way as any other vulnerability.
