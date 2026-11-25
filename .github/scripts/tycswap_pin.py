#!/usr/bin/env python3
"""Move flake.nix's tycswap pin to the newest tycswap release through a self-merging pull request.

`plan` prints the step this run takes (none, close, finish or pin) for the workflow's
`if:`; `act` plans again and takes it. Run by .github/workflows/tycswap-pin.yml.
"""

import argparse
import base64
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

UPSTREAM = "tyclab/tycswap"
BRANCH_PREFIX = "tycswap-pin/"
BOT_LOGIN = "github-actions[bot]"
BOT_EMAIL = "41898282+github-actions[bot]@users.noreply.github.com"
CI_WORKFLOW = "ci.yml"
LABEL = "dependencies"
FAKE_HASH = "sha256-" + "A" * 43 + "="
TAG = re.compile(r"^v(\d+)\.(\d+)\.(\d+)$")
LIST_ITEM = re.compile(r"^\s*(?:[-*+]|\d+[.)])\s+(.*)$")
MISMATCH = re.compile(
    r"hash mismatch in fixed-output derivation '(?P<drv>[^']+)':\s*"
    r"specified:\s*\S+\s*got:\s*(?P<got>sha256-[A-Za-z0-9+/]+=*)"
)
# Field -> (block, pattern): block 0 is `tycswap = ...`, block 1 is `tycswapWindows = ...`.
FIELDS = {
    "version": (0, r'^\s*version = "([^"]+)";$'),
    "src": (0, r'^\s*hash = "(sha256-[^"]+)";$'),
    "vendor": (0, r'^\s*vendorHash = "(sha256-[^"]+)";$'),
    "windows": (1, r'^\s*hash = "(sha256-[^"]+)";$'),
}


class PinError(Exception):
    """Nothing is published; the next run tries again."""


class BuildFailure(Exception):
    """The pin is published anyway, so the failure shows on its pull request."""

    def __init__(self, step, log):
        super().__init__(f"{step} failed")
        self.step, self.log = step, log


def vkey(version):
    m = TAG.match("v" + version.removeprefix("v"))
    return tuple(int(x) for x in m.groups()) if m else None


def sri(hex_digest):
    return "sha256-" + base64.b64encode(bytes.fromhex(hex_digest)).decode()


def windows_asset(version):
    return f"tycswap_v{version}_windows_amd64.exe"


@dataclass
class Release:
    version: str
    url: str
    body: str
    assets: dict
    windows_hex: str = ""


@dataclass
class PinPR:
    number: int
    ref: str
    head_sha: str
    version: str
    armed: bool = False


@dataclass
class Plan:
    action: str
    reason: str
    target: Release | None = None
    pending: list = field(default_factory=list)
    keep: PinPR | None = None
    close: list = field(default_factory=list)


def published(releases_json):
    rels = [
        Release(r["tag_name"][1:], r["html_url"], r.get("body") or "", {a["name"]: a for a in r.get("assets", [])})
        for r in releases_json
        if not r.get("draft") and not r.get("prerelease") and TAG.match(r.get("tag_name", ""))
    ]
    return sorted(rels, key=lambda r: vkey(r.version))


def pr_version(ref):
    m = re.match(re.escape(BRANCH_PREFIX) + r"v(\d+\.\d+\.\d+)-[0-9a-f]+$", ref)
    return m.group(1) if m else None


def blocks(text):
    start = re.search(r"^\s*tycswap =\s*$", text, re.M)
    win = re.search(r"^\s*tycswapWindows = pkgs\.fetchurl \{\s*$", text, re.M)
    end = re.search(r"^\s*tycswapOverlay = ", text, re.M)
    if not (start and win and end and start.start() < win.start() < end.start()):
        raise PinError("flake.nix: the tycswap, tycswapWindows and tycswapOverlay bindings are not where FIELDS expects them")
    return [(start.start(), win.start()), (win.start(), end.start())]


def read_pin(text):
    spans, values = blocks(text), {}
    for name, (block, pattern) in FIELDS.items():
        lo, hi = spans[block]
        found = re.findall(pattern, text[lo:hi], re.M)
        if len(found) != 1:
            raise PinError(f"flake.nix: expected one {name} in the tycswap pin, found {len(found)}")
        values[name] = found[0]
    return values


def write_pin(text, values):
    read_pin(text)
    for name, value in values.items():
        block, pattern = FIELDS[name]
        lo, hi = blocks(text)[block]
        part = re.sub(pattern, lambda m: m.group(0).replace(m.group(1), value), text[lo:hi], count=1, flags=re.M)
        text = text[:lo] + part + text[hi:]
    return text


def first_paragraph(body):
    """The notes' first prose paragraph, or the first item's text when they open with a list."""
    for block in re.split(r"\n\s*\n", body.replace("\r\n", "\n")):
        lines = block.strip().splitlines()
        if not lines or lines[0].startswith("#"):
            continue
        if first := LIST_ITEM.match(lines[0]):
            rest = next((i for i, line in enumerate(lines[1:], 1) if LIST_ITEM.match(line)), len(lines))
            lines = [first[1], *lines[1:rest]]
        if text := " ".join(line.strip() for line in lines).strip():
            return text
    return ""


def changelog_lines(pending):
    target = pending[-1]
    lines = []
    for rel in reversed(pending):
        head = (
            f"Pin tycswap and its Windows tray to v{rel.version}."
            if rel is target
            else f"tycswap v{rel.version}, which the v{target.version} pin includes:"
        )
        lines.append(" ".join(part for part in ("-", head, first_paragraph(rel.body), f"([release notes]({rel.url}))") if part))
    return lines


def add_changelog(text, lines):
    rows = text.split("\n")
    start = next((i for i, r in enumerate(rows) if r.startswith("## [Unreleased]")), None)
    if start is None:
        raise PinError("CHANGELOG.md has no ## [Unreleased] section")
    end = next((i for i in range(start + 1, len(rows)) if rows[i].startswith("## ")), len(rows))
    changed = next((i for i in range(start, end) if rows[i] == "### Changed"), None)
    if changed is not None:
        at = changed + 1 + (rows[changed + 1] == "")
        rows[at:at] = lines
    else:
        later = ("### Deprecated", "### Removed", "### Fixed", "### Security")
        at = next((i for i in range(start, end) if rows[i] in later), end)
        rows[at:at] = ["### Changed", "", *lines, ""]
    return "\n".join(rows)


def pr_title(version):
    return f"chore(tycswap): pin tycswap and its Windows tray to v{version}"


def pr_body(plan, before, values, failure, run_url):
    rel = plan.target
    vendor = "unchanged" if values["vendor"] == before["vendor"] else f"was `{before['vendor']}`"
    parts = [f"Pins tycswap and its Windows tray to [v{rel.version}]({rel.url})."]
    for r in reversed(plan.pending):
        parts.append(f"**[v{r.version}]({r.url})**" + (f": {first_paragraph(r.body)}" if first_paragraph(r.body) else ""))
    if failure:
        parts.append(
            f"**This pin does not build ({failure.step}):** the run that opened it could not finish the pin, "
            f"so `test` fails here until main or this branch is fixed.\n\n```text\n{failure.log}\n```"
        )
    parts.append(
        "\n".join(
            [
                f"- `version`: `{values['version']}`",
                f"- source `hash`: `{values['src']}`, nix's own hash of `fetchFromGitHub` at tag `v{rel.version}`",
                f"- Windows `hash`: `{values['windows']}`, `{windows_asset(rel.version)}` in the release's "
                f"`SHA256SUMS` (`{rel.windows_hex}`)",
                f"- `vendorHash`: `{values['vendor']}` ({vendor}), nix's own hash of the Go module vendor directory",
                f"\nComputed and opened by the tycswap pin workflow ({run_url}); it merges itself once "
                "`lint`, `test` and `gitleaks` pass on an up-to-date branch.",
                f"\nClosing this pull request, or reverting its pin after the merge, holds v{rel.version}: the "
                "workflow opens no other pin for it and pins the next release as usual. To take a held release "
                "after all, reopen this pull request and turn auto-merge on again, or pin it by hand.",
            ]
        )
    )
    return "\n\n".join(parts)


def run(cmd, cwd=None, check=True):
    try:
        proc = subprocess.run(cmd, cwd=cwd, text=True, capture_output=True)
    except FileNotFoundError as e:
        raise PinError(f"{cmd[0]} is not installed (the plan step installs nix only for a pin)") from e
    if check and proc.returncode != 0:
        raise PinError(f"{' '.join(cmd)}: {proc.stderr.strip() or proc.stdout.strip()}")
    return proc


class GitHub:
    def __init__(self, repo):
        self.repo = repo

    def api(self, path, *args):
        return json.loads(run(["gh", "api", path, *args]).stdout or "null")

    def releases(self):
        return self.api(f"repos/{UPSTREAM}/releases?per_page=100")

    def asset_text(self, asset):
        return run(["gh", "api", "-H", "Accept: application/octet-stream", f"repos/{UPSTREAM}/releases/assets/{asset['id']}"]).stdout

    def api_list(self, path):
        lines = run(["gh", "api", "--paginate", path, "--jq", ".[]"]).stdout.splitlines()
        return [json.loads(line) for line in lines if line.strip()]

    def pulls(self, state):
        return self.api_list(f"repos/{self.repo}/pulls?state={state}&per_page=100")

    def here(self, p):
        return bool(p["head"]["repo"]) and p["head"]["repo"]["full_name"] == self.repo

    def pin_prs(self, state, raw=None):
        """This workflow's pin pull requests: opened by its bot from a branch of this repository."""
        return [
            (PinPR(p["number"], p["head"]["ref"], p["head"]["sha"], pr_version(p["head"]["ref"]), bool(p.get("auto_merge"))), p)
            for p in (self.pulls(state) if raw is None else raw)
            if (p.get("user") or {}).get("login") == BOT_LOGIN and self.here(p) and pr_version(p["head"]["ref"])
        ]

    def settled(self, version):
        """A pin pull request for `version` that was merged, or closed by someone other than the workflow."""
        for pr, raw in self.pin_prs("closed"):
            if pr.version != version:
                continue
            if raw.get("merged_at"):
                return pr.number, "merged"
            closer = (self.api(f"repos/{self.repo}/issues/{pr.number}").get("closed_by") or {}).get("login")
            if closer != BOT_LOGIN:
                return pr.number, "closed by hand"
        return None

    def behind_by(self, base_sha, head_sha):
        return self.api(f"repos/{self.repo}/compare/{base_sha}...{head_sha}")["behind_by"]

    def ci_runs(self, head_sha):
        """CI runs on the head, not counting a pull_request run that waits for someone's approval."""
        runs = self.api(f"repos/{self.repo}/actions/workflows/{CI_WORKFLOW}/runs?head_sha={head_sha}")["workflow_runs"]
        return sum("action_required" not in (r.get("status"), r.get("conclusion")) for r in runs)

    def create_pr(self, branch, title, body):
        out = run(["gh", "pr", "create", "--repo", self.repo, "--base", "main", "--head", branch,
                   "--title", title, "--body", body, "--label", LABEL]).stdout  # fmt: skip
        return int(out.strip().rstrip("/").rsplit("/", 1)[1])

    def close_pr(self, number, comment):
        run(["gh", "pr", "close", str(number), "--repo", self.repo, "--comment", comment, "--delete-branch"])

    def arm_automerge(self, number):
        run(["gh", "pr", "merge", str(number), "--repo", self.repo, "--auto", "--merge"])

    def dispatch_ci(self, branch):
        run(["gh", "workflow", "run", CI_WORKFLOW, "--repo", self.repo, "--ref", branch])


class Nix:
    def __init__(self, repo, flake="."):
        self.repo, self.flake = repo, flake

    def build(self, *attrs):
        proc = run(["nix", "build", "--no-link", "--print-build-logs", *(f"{self.flake}#{a}" for a in attrs)], self.repo, False)
        return proc.returncode == 0, proc.stdout + proc.stderr

    def pinned(self):
        expr = "p: { inherit (p) version; src = p.src.outputHash; vendor = p.goModules.outputHash; }"
        pkg, win = f"{self.flake}#packages.x86_64-linux.tycswap", f"{self.flake}#checks.x86_64-linux.tycswap-windows.outputHash"
        got = json.loads(run(["nix", "eval", "--json", pkg, "--apply", expr], self.repo).stdout)
        got["windows"] = json.loads(run(["nix", "eval", "--json", win], self.repo).stdout)
        return got

    def lint_changelog(self):
        # The first prettier run may rewrite the line; the second and markdownlint must pass.
        procs = [
            run(["nix", "develop", "-c", "pre-commit", "run", hook, "--files", "CHANGELOG.md"], self.repo, False)
            for hook in ("prettier", "prettier", "markdownlint-cli2")
        ]
        return all(p.returncode == 0 for p in procs[1:]), "".join(p.stdout + p.stderr for p in procs[1:])


class Git:
    def __init__(self, repo):
        self.repo = repo

    def head(self):
        return run(["git", "rev-parse", "HEAD"], self.repo).stdout.strip()

    def commit_and_push(self, message, branch):
        ident = ["-c", f"user.name={BOT_LOGIN}", "-c", f"user.email={BOT_EMAIL}"]
        run(["git", *ident, "commit", "-m", message, "--", "flake.nix", "CHANGELOG.md"], self.repo)
        # A branch of this name without a pull request is an earlier attempt from the same main.
        run(["git", "push", "--force", "origin", f"HEAD:refs/heads/{branch}"], self.repo)


def ready(gh, rel):
    exe, sums = rel.assets.get(windows_asset(rel.version)), rel.assets.get("SHA256SUMS")
    if not (exe and sums and exe.get("state", "uploaded") == "uploaded" and sums.get("state", "uploaded") == "uploaded"):
        return False
    for line in gh.asset_text(sums).splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[1].lstrip("*") == exe["name"]:
            rel.windows_hex = parts[0].lower()
    digest = exe.get("digest") or ""
    if rel.windows_hex and digest and digest != f"sha256:{rel.windows_hex}":
        raise PinError(f"v{rel.version}: SHA256SUMS names {rel.windows_hex}, GitHub's digest of the exe is {digest}")
    return bool(rel.windows_hex)


def pin_branch(version, main_sha):
    return f"{BRANCH_PREFIX}v{version}-{main_sha[:8]}"


def plan(pinned, gh, main_sha):
    if vkey(pinned) is None:
        raise PinError(f"flake.nix pins tycswap {pinned!r}, not X.Y.Z")
    rels = [r for r in published(gh.releases()) if vkey(r.version) > vkey(pinned)]
    raw_open = gh.pulls("open")
    open_prs = [pr for pr, _ in gh.pin_prs("open", raw_open)]
    if not rels:
        if open_prs:
            return Plan("close", f"main pins v{pinned}", close=[(pr, f"main already pins v{pinned}.") for pr in open_prs])
        return Plan("none", f"main pins v{pinned}, the newest release")
    target = rels[-1]
    if not ready(gh, target):
        return Plan("none", f"v{target.version} has no {windows_asset(target.version)} line in SHA256SUMS yet")
    keep = next((p for p in open_prs if p.version == target.version and gh.behind_by(main_sha, p.head_sha) == 0), None)
    stale = [(p, "main moved on." if p.version == target.version else f"v{target.version} is newer.") for p in open_prs if p is not keep]
    if keep is None:
        held = gh.settled(target.version)
        if held and held[1] == "merged":
            return Plan("none", f"v{target.version} is held: its pin #{held[0]} was merged and main pins v{pinned} again; pin it by hand to take it")
        if held:
            return Plan("none", f"v{target.version} is held: #{held[0]} was closed by hand; reopen it or pin by hand to take it")
        branch = pin_branch(target.version, main_sha)
        taken = [p["number"] for p in raw_open if gh.here(p) and p["head"]["ref"] == branch and p["number"] not in {o.number for o in open_prs}]
        if taken:
            return Plan("none", f"branch {branch} is the head of #{taken[0]}, which the workflow did not open")
        return Plan("pin", f"main pins v{pinned}, v{target.version} is out", target, rels, close=stale)
    if gh.ci_runs(keep.head_sha) == 0:
        return Plan("finish", f"#{keep.number} has no CI run yet", target, rels, keep, stale)
    if stale:
        return Plan("close", f"#{keep.number} pins v{target.version}", target, rels, keep, stale)
    return Plan("none", f"#{keep.number} pins v{target.version} on the current main", target, rels, keep)


def tail(out):
    return "\n".join(out.replace("```", "'''").strip().splitlines()[-30:])


def build(nix, *attrs):
    """One retry for a failure that is not a hash mismatch: a download can fail once."""
    ok, out = nix.build(*attrs)
    if not ok and not MISMATCH.search(out):
        ok, out = nix.build(*attrs)
    return ok, out


def build_or_hash(nix, attr, drv_suffix):
    ok, out = build(nix, attr)
    if ok:
        return None
    found = {m["got"] for m in MISMATCH.finditer(out) if m["drv"].endswith(drv_suffix)}
    if len(found) != 1:
        raise BuildFailure(attr, tail(out))
    return found.pop()


def compute(repo, nix, target):
    flake = repo / "flake.nix"
    values = read_pin(flake.read_text())
    values.update(version=target.version, src=FAKE_HASH, windows=sri(target.windows_hex))
    flake.write_text(write_pin(flake.read_text(), values))
    try:
        got = build_or_hash(nix, "packages.x86_64-linux.tycswap.src", "-source.drv")
    except BuildFailure as e:
        raise PinError(f"the source of v{target.version} did not fetch:\n{e.log}") from e
    if got is None:
        raise PinError("the source built under the placeholder hash")
    values["src"] = got
    flake.write_text(write_pin(flake.read_text(), values))
    try:
        vendor = build_or_hash(nix, "packages.x86_64-linux.tycswap.goModules", "-go-modules.drv")
        if vendor:
            values["vendor"] = vendor
            flake.write_text(write_pin(flake.read_text(), values))
        ok, out = build(nix, "checks.x86_64-linux.tycswap", "checks.x86_64-linux.tycswap-windows")
        if not ok:
            raise BuildFailure("checks.tycswap and checks.tycswap-windows", tail(out))
    except BuildFailure as e:
        return values, e
    evaluated = nix.pinned()
    if evaluated != values:
        raise PinError(f"flake.nix evaluates to {evaluated}, not the written {values}")
    return values, None


def act(p, repo, gh, nix, git, main_sha, run_url):
    for pr, why in [] if p.action == "pin" else p.close:
        gh.close_pr(pr.number, f"Superseded by #{p.keep.number}: {why}" if p.keep else f"Closed by the tycswap pin workflow: {why}")
    if p.action == "finish":
        if not p.keep.armed:
            gh.arm_automerge(p.keep.number)
        gh.dispatch_ci(p.keep.ref)
    if p.action != "pin":
        return None
    before = read_pin((repo / "flake.nix").read_text())
    values, failure = compute(repo, nix, p.target)
    changelog = repo / "CHANGELOG.md"
    changelog.write_text(add_changelog(changelog.read_text(), changelog_lines(p.pending)))
    if failure is None:
        ok, out = nix.lint_changelog()
        failure = None if ok else BuildFailure("lint of CHANGELOG.md", tail(out))
    branch = pin_branch(p.target.version, main_sha)
    git.commit_and_push(pr_title(p.target.version), branch)
    number = gh.create_pr(branch, pr_title(p.target.version), pr_body(p, before, values, failure, run_url))
    for pr, why in p.close:
        gh.close_pr(pr.number, f"Superseded by #{number}: {why}")
    gh.arm_automerge(number)
    gh.dispatch_ci(branch)
    return number


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("command", choices=["plan", "act"])
    parser.add_argument("--repo-dir", type=Path, default=Path.cwd())
    args = parser.parse_args(argv)
    env = os.environ
    if env.get("GITHUB_REF", "refs/heads/main") != "refs/heads/main":
        print(f"tycswap-pin: runs on main only, not {env['GITHUB_REF']}", file=sys.stderr)
        return 2
    repo = env.get("GITHUB_REPOSITORY", "tyclab/flakelab")
    gh, git = GitHub(repo), Git(args.repo_dir)
    run_url = f"{env.get('GITHUB_SERVER_URL', 'https://github.com')}/{repo}/actions/runs/{env.get('GITHUB_RUN_ID', '')}"
    try:
        main_sha = git.head()
        p = plan(read_pin((args.repo_dir / "flake.nix").read_text())["version"], gh, main_sha)
        line = f"{p.action}: {p.reason}"
        if args.command == "act":
            number = act(p, args.repo_dir, gh, Nix(args.repo_dir), git, main_sha, run_url)
            line += f"; opened #{number}" if number else ""
    except PinError as e:
        print(f"tycswap-pin: {e}", file=sys.stderr)
        return 1
    print(line)
    for key, text in (("GITHUB_OUTPUT", f"action={p.action}"), ("GITHUB_STEP_SUMMARY", f"tycswap pin: {line}")):
        if env.get(key):
            with open(env[key], "a", encoding="utf-8") as out:
                out.write(text + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
