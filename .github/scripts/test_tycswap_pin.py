"""tycswap_pin against a fake release list, fake pull requests and a fake nix; FLAKELAB_TYCSWAP_PIN_LIVE=1 adds the real releases."""

import contextlib
import io
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import tycswap_pin as tp  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
REPO = "tyclab/flakelab"
MAIN = "1111111111111111111111111111111111111111"
NEXT_MAIN = "2222222222222222222222222222222222222222"
# v0.23.2 and v0.23.3 as GitHub serves them, and the values committed by hand in 3a3fbf0 and c69fb76.
WIN_HEX = {
    "0.23.2": "b5904f3630f4d1b0e127ddab3d028701de33470cc85246e42db07ff136f8d33f",
    "0.23.3": "c2a3fcdb2d9330889eca5022fd5db4f9926d746acd6a914a560fb6b1a4e05dff",
}
BY_HAND_WINDOWS = {
    "0.23.2": "sha256-tZBPNjD00bDhJ92rPQKHAd4zRwzIUkbkLbB/8Tb40z8=",
    "0.23.3": "sha256-wqP82y2TMIieylAi/V20+ZJtdGrNapFKVg+2saTgXf8=",
}
REAL_MISMATCH = """building '/nix/store/3fk7h452pkq740w85il9w8r6ainrqa0k-source.drv'...
error: hash mismatch in fixed-output derivation '/nix/store/3fk7h452pkq740w85il9w8r6ainrqa0k-source.drv':
         specified: sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
            got:    sha256-h/2CIdih09e5cujNg8Ym9zMxBYzoxPqDal7qaSvYeAY=
"""


def hex_for(version):
    return WIN_HEX.get(version, f"{int(version.replace('.', '')):064x}")


def release(version, body=None, exe=True, sums=True, sums_line=True, draft=False, prerelease=False):
    hex_digest = hex_for(version)
    assets = []
    if exe:
        assets.append({"id": f"exe-{version}", "name": tp.windows_asset(version), "state": "uploaded", "digest": f"sha256:{hex_digest}"})
    if sums:
        assets.append({"id": f"sums-{version}", "name": "SHA256SUMS", "state": "uploaded", "hex": hex_digest if sums_line else None})
    return {
        "tag_name": f"v{version}",
        "html_url": f"https://github.com/tyclab/tycswap/releases/tag/v{version}",
        "body": body if body is not None else f"Summary of {version}.\nSecond line.\n\n- **Detail.** More.\n",
        "draft": draft,
        "prerelease": prerelease,
        "assets": assets,
    }


class FakeGitHub(tp.GitHub):
    """The read paths and the approval go through the real GitHub methods; `api` answers from this model."""

    def __init__(self, releases):
        super().__init__(REPO)
        self.release_list, self.main = releases, MAIN
        self.prs, self.runs, self.branches, self.calls = {}, {}, {}, []
        self.number, self.fail = 500, set()
        # GitHub's clock: a pull request's CI run shows `run_delay` seconds after it is opened (4 s for #450).
        self.clock, self.run_delay, self.run_id, self.approved, self.refuse = 0, 4, 9000, [], None
        self.held = True

    def _maybe_fail(self, name):
        self.calls.append(name)
        if name in self.fail:
            self.fail.discard(name)
            raise tp.PinError(f"injected failure in {name}")

    def api(self, path, *args):
        if path.startswith(f"repos/{tp.UPSTREAM}/releases?"):
            return self.release_list
        if m := re.match(rf"repos/{REPO}/pulls\?state=(\w+)", path):
            states = {"open": ("open",), "closed": ("closed", "merged")}[m[1]]
            return [self._raw(p) for p in sorted(self.prs.values(), key=lambda p: -p["number"]) if p["state"] in states]
        if m := re.match(rf"repos/{REPO}/issues/(\d+)$", path):
            return {"closed_by": {"login": self.prs[int(m[1])]["closed_by"]}}
        if m := re.match(rf"repos/{REPO}/compare/(\w+)\.\.\.(\w+)$", path):
            base = next(p["base"] for p in self.prs.values() if p["sha"] == m[2])
            return {"behind_by": 0 if base == m[1] else 1}
        if m := re.match(rf"repos/{REPO}/actions/workflows/ci.yml/runs\?head_sha=(\w+)&event=pull_request$", path):
            return {"workflow_runs": [r for r in self.runs.get(m[1], []) if r["shown"] <= self.clock]}
        if m := re.match(rf"repos/{REPO}/actions/runs/(\d+)/approve$", path):
            if args != ("-X", "POST"):
                raise AssertionError(f"approve sent as {args}, not a POST")
            self._maybe_fail("approve")
            if self.refuse:
                raise tp.PinError(f"gh api {path} {' '.join(args)}: {self.refuse}")
            (run,) = [r for runs in self.runs.values() for r in runs if r["id"] == int(m[1]) and r["shown"] <= self.clock]
            if run["conclusion"] != "action_required":
                raise AssertionError(f"approved run {run['id']}, which does not wait for approval")
            run.update(status="queued", conclusion=None)
            self.approved.append(run["id"])
            return {}
        raise AssertionError(f"unexpected api path {path}")

    def add_run(self, sha, delay, held=True):
        """The pull_request run GitHub creates and holds for approval, as for a pull request github-actions[bot] opened."""
        self.run_id += 1
        state = dict(status="completed", conclusion="action_required") if held else dict(status="queued", conclusion=None)
        run = dict(id=self.run_id, event="pull_request", shown=self.clock + delay, **state)
        self.runs.setdefault(sha, []).append(run)
        return run

    def run_of(self, number):
        (run,) = self.runs[self.prs[number]["sha"]]
        return run

    def sleep(self, seconds):
        self.clock += seconds

    def api_list(self, path):
        return self.api(path)

    def _raw(self, p):
        repo = p.get("repo", REPO)
        head = {"ref": p["ref"], "sha": p["sha"], "repo": {"full_name": repo} if repo else None}
        return {
            "number": p["number"],
            "user": {"login": p.get("author", tp.BOT_LOGIN)},
            "head": head,
            "auto_merge": {"merge_method": "merge"} if p["armed"] else None,
            "merged_at": "2026-11-25T12:00:00Z" if p["state"] == "merged" else None,
        }

    def add_pr(self, ref, version_base=MAIN, **fields):
        """A pull request opened by someone else, from `ref`."""
        self.number += 1
        self.prs[self.number] = dict(number=self.number, ref=ref, sha=f"{self.number:040x}", base=version_base, state="open",
                                     armed=False, title="t", body="b", closed_by=None, **fields)  # fmt: skip
        # Held like the workflow's own, so a guard that let this pull request through would approve its run.
        self.add_run(self.prs[self.number]["sha"], 0)
        return self.number

    def asset_text(self, asset):
        self.calls.append("asset_text")
        rel = next(r for r in self.release_list if asset in r["assets"])
        version = rel["tag_name"][1:]
        exe = f"{asset['hex']}  {tp.windows_asset(version)}\n" if asset["hex"] else ""
        return f"{'0' * 64}  tycswap_v{version}_linux_amd64\n{exe}"

    def create_pr(self, branch, title, body):
        self._maybe_fail("create_pr")
        self.number += 1
        sha, base = self.branches[branch]
        self.prs[self.number] = dict(number=self.number, ref=branch, sha=sha, base=base, state="open", armed=False, title=title, body=body, closed_by=None)
        if self.run_delay is not None:
            self.add_run(sha, self.run_delay, self.held)
        return self.number

    def close_pr(self, number, comment):
        self._maybe_fail("close_pr")
        self.prs[number].update(state="closed", closed_by=tp.BOT_LOGIN, comment=comment)
        self.branches.pop(self.prs[number]["ref"], None)

    def arm_automerge(self, number):
        self._maybe_fail("arm_automerge")
        self.prs[number]["armed"] = True

    def open(self):
        return [p for p in self.prs.values() if p["state"] == "open"]


class FakeGit:
    def __init__(self, gh):
        self.gh, self.pushes = gh, 0

    def head(self):
        return self.gh.main

    def commit_and_push(self, message, branch):
        self.pushes += 1
        self.gh.branches[branch] = (f"{self.pushes:040x}", self.gh.main)
        return self.gh.branches[branch][0]


class FakeNix:
    """Answers like nix for the pin in flake.nix: a mismatch names the true hash."""

    def __init__(self, repo, truth):
        self.repo, self.truth, self.builds, self.src_builds = repo, truth, [], []
        self.broken, self.flaky, self.store, self.misreport, self.evaluates = set(), set(), set(), {}, None

    def build(self, *attrs):
        self.builds.append(attrs)
        pin = tp.read_pin((self.repo / "flake.nix").read_text())
        for attr in attrs:
            if attr == "packages.x86_64-linux.tycswap.src":
                self.src_builds.append(pin["src"])
            if attr in self.misreport:
                return False, (
                    f"error: hash mismatch in fixed-output derivation '/nix/store/abc-{self.misreport[attr]}.drv':\n"
                    f"         specified: {pin['src']}\n            got:    sha256-OTHER{'o' * 37}=\n"
                )
            if attr in self.flaky:
                self.flaky.discard(attr)
                return False, "error: unable to download: HTTP error 502"
            if attr in self.broken:
                return False, f"error: builder for '/nix/store/x-{attr}.drv' failed with exit code 1"
            field, drv = {
                "packages.x86_64-linux.tycswap.src": ("src", "source"),
                "packages.x86_64-linux.tycswap.goModules": ("vendor", f"tycswap-{pin['version']}-go-modules"),
                "checks.x86_64-linux.tycswap-windows": ("windows", tp.windows_asset(pin["version"])),
            }.get(attr, (None, None))
            for f, d in [(field, drv)] if field else [("src", "source"), ("vendor", f"tycswap-{pin['version']}-go-modules")]:
                # A source path already in the store is not fetched again, whatever version it holds.
                if pin[f] != self.truth[f] and not (f == "src" and pin[f] in self.store):
                    return False, (
                        f"error: hash mismatch in fixed-output derivation '/nix/store/abc-{d}.drv':\n"
                        f"         specified: {pin[f]}\n            got:    {self.truth[f]}\n"
                    )
        return True, ""

    def pinned(self):
        return self.evaluates or tp.read_pin((self.repo / "flake.nix").read_text())

    def lint_changelog(self):
        return "lint" not in self.broken, "markdownlint: MD999 broken" if "lint" in self.broken else ""


class Box:
    """A checkout of main with its flake.nix and CHANGELOG.md, plus the fakes around it."""

    def __init__(self, test, releases, pinned="0.23.3"):
        tmp = tempfile.TemporaryDirectory()
        test.addCleanup(tmp.cleanup)
        self.repo = Path(tmp.name)
        flake = (ROOT / "flake.nix").read_text()
        self.main_pin = dict(tp.read_pin(flake), version=pinned)
        (self.repo / "flake.nix").write_text(tp.write_pin(flake, self.main_pin))
        (self.repo / "CHANGELOG.md").write_text((ROOT / "CHANGELOG.md").read_text())
        self.gh = FakeGitHub(releases)
        self.git = FakeGit(self.gh)
        self.truth = {"src": "sha256-SRC" + "s" * 39 + "=", "vendor": self.main_pin["vendor"]}
        self.nix = FakeNix(self.repo, self.truth)
        self.nix.store.add(self.main_pin["src"])
        self.main_files = {n: (self.repo / n).read_text() for n in ("flake.nix", "CHANGELOG.md")}
        self.ci = None

    def checkout(self):
        """A fresh checkout of main, a quarter hour after the last run."""
        self.gh.clock += 900
        for name, text in self.main_files.items():
            (self.repo / name).write_text(text)

    def tick(self):
        """One workflow run: plan, then act."""
        self.checkout()
        pinned = tp.read_pin((self.repo / "flake.nix").read_text())["version"]
        p = tp.plan(pinned, self.gh, self.git.head())
        if p.target:
            self.truth["windows"] = tp.sri(p.target.windows_hex)
        number, self.ci = tp.act(p, self.repo, self.gh, self.nix, self.git, self.git.head(), "https://example.invalid/run")
        return p, number

    def act_step(self):
        """The workflow's act step through main(): its exit code, stdout and stderr."""
        self.checkout()
        self.truth["windows"] = tp.sri(hex_for(tp.published(self.gh.release_list)[-1].version))
        out, err = io.StringIO(), io.StringIO()
        env = {"GITHUB_REF": "refs/heads/main", "GITHUB_REPOSITORY": REPO}
        with mock.patch.dict(os.environ, env, clear=True), mock.patch.object(tp, "GitHub", return_value=self.gh), \
                mock.patch.object(tp, "Git", return_value=self.git), mock.patch.object(tp, "Nix", return_value=self.nix), \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):  # fmt: skip
            rc = tp.main(["act", "--repo-dir", str(self.repo)])
        return rc, out.getvalue(), err.getvalue()

    def merge(self, number):
        """Main takes the pull request's files, as the merge commit would."""
        self.gh.prs[number].update(state="merged")
        self.main_files = {n: (self.repo / n).read_text() for n in ("flake.nix", "CHANGELOG.md")}
        self.gh.main = NEXT_MAIN if self.gh.main == MAIN else MAIN


class PureTests(unittest.TestCase):
    def test_sri_reproduces_the_windows_hashes_committed_by_hand(self):
        for version, hex_digest in WIN_HEX.items():
            self.assertEqual(tp.sri(hex_digest), BY_HAND_WINDOWS[version])

    def test_mismatch_parse_reads_real_nix_output(self):
        self.assertEqual([m["got"] for m in tp.MISMATCH.finditer(REAL_MISMATCH)], ["sha256-h/2CIdih09e5cujNg8Ym9zMxBYzoxPqDal7qaSvYeAY="])

    def test_pin_round_trip_on_the_real_flake_touches_four_lines(self):
        flake = (ROOT / "flake.nix").read_text()
        pin = tp.read_pin(flake)
        self.assertEqual(set(pin), {"version", "src", "vendor", "windows"})
        new = {"version": "9.9.9", "src": "sha256-1=", "vendor": "sha256-2=", "windows": "sha256-3="}
        written = tp.write_pin(flake, new)
        self.assertEqual(tp.read_pin(written), new)
        changed = [(a, b) for a, b in zip(flake.splitlines(), written.splitlines()) if a != b]
        self.assertEqual(len(changed), 4)
        self.assertEqual(len(flake.splitlines()), len(written.splitlines()))

    def test_a_changed_layout_is_refused_not_guessed(self):
        flake = (ROOT / "flake.nix").read_text()
        with self.assertRaisesRegex(tp.PinError, "bindings"):
            tp.read_pin(flake.replace("tycswapWindows = pkgs.fetchurl {", "tycswapWin = pkgs.fetchurl {"))
        doubled = flake.replace('vendorHash = "', 'hash = "sha256-x=";\n          vendorHash = "', 1)
        with self.assertRaisesRegex(tp.PinError, "one src"):
            tp.read_pin(doubled)

    def test_first_paragraph_of_prose_and_of_a_list(self):
        self.assertEqual(tp.first_paragraph("# Title\r\n\r\nOne\r\ntwo.\r\n\r\nRest"), "One two.")
        notes = "- **Fixed: a move timed out.** Since v0.20.0\n  it waited.\n- **The guard lends its lock.** More.\n"
        self.assertEqual(tp.first_paragraph(notes), "**Fixed: a move timed out.** Since v0.20.0 it waited.")
        self.assertEqual(tp.first_paragraph("## Changed\n\n1. One\n2. Two\n"), "One")
        self.assertEqual(tp.first_paragraph(""), "")

    def test_changelog_gets_a_changed_section_where_keep_a_changelog_puts_it(self):
        text = "# Changelog\n\n## [Unreleased]\n\n### Added\n\n- a\n\n### Fixed\n\n- f\n\n## [1.0.0]\n"
        out = tp.add_changelog(text, ["- pin"])
        self.assertIn("### Added\n\n- a\n\n### Changed\n\n- pin\n\n### Fixed", out)

    def test_main_only(self):
        with tempfile.TemporaryDirectory() as tmp, mock.patch.dict(os.environ, {"GITHUB_REF": "refs/heads/feature"}), \
                mock.patch.object(tp, "run", side_effect=AssertionError("ran a command off main")):  # fmt: skip
            self.assertEqual(tp.main(["plan", "--repo-dir", tmp]), 2)

    def test_versions_compare_as_numbers(self):
        self.assertGreater(tp.vkey("0.10.0"), tp.vkey("0.9.9"))
        self.assertIsNone(tp.vkey("1.0.0-rc1"))


class LifecycleTests(unittest.TestCase):
    def test_a_release_already_pinned_opens_nothing(self):
        box = Box(self, [release("0.23.2"), release("0.23.3")])
        p, number = box.tick()
        self.assertEqual((p.action, number), ("none", None))
        self.assertEqual(box.gh.calls, [])

    def test_a_new_release_becomes_one_correct_armed_pull_request(self):
        box = Box(self, [release("0.23.3"), release("0.23.4")])
        p, number = box.tick()
        self.assertEqual(p.action, "pin")
        pr = box.gh.prs[number]
        self.assertEqual(pr["ref"], f"tycswap-pin/v0.23.4-{MAIN[:8]}")
        self.assertEqual(pr["title"], "chore(tycswap): pin tycswap and its Windows tray to v0.23.4")
        self.assertTrue(pr["armed"])
        self.assertEqual(box.gh.approved, [box.gh.run_of(number)["id"]])
        pin = tp.read_pin((box.repo / "flake.nix").read_text())
        self.assertEqual(pin, {"version": "0.23.4", "src": box.truth["src"], "vendor": box.truth["vendor"], "windows": box.truth["windows"]})
        changelog = (box.repo / "CHANGELOG.md").read_text()
        top = changelog.split("### Changed\n\n", 1)[1].splitlines()[0]
        self.assertEqual(top, "- Pin tycswap and its Windows tray to v0.23.4. Summary of 0.23.4. Second line. "
                              "([release notes](https://github.com/tyclab/tycswap/releases/tag/v0.23.4))")  # fmt: skip
        self.assertIn("Summary of 0.23.4. Second line.", pr["body"])
        self.assertIn(hex_for("0.23.4"), pr["body"])
        self.assertNotIn("does not build", pr["body"])
        self.assertIn(f"`{box.truth['vendor']}` (unchanged)", pr["body"])
        self.assertEqual(box.tick()[0].action, "none")
        self.assertEqual(len(box.gh.open()), 1)

    def test_a_changed_vendor_hash_is_computed_and_written(self):
        box = Box(self, [release("0.23.4")])
        box.truth["vendor"] = "sha256-NEWVENDOR" + "v" * 33 + "="
        _, number = box.tick()
        self.assertEqual(tp.read_pin((box.repo / "flake.nix").read_text())["vendor"], box.truth["vendor"])
        self.assertIn(f"`{box.truth['vendor']}` (was `{box.main_pin['vendor']}`)", box.gh.prs[number]["body"])

    def test_two_releases_in_a_row_end_on_the_newest(self):
        rels = [release("0.23.3"), release("0.23.4")]
        box = Box(self, rels)
        _, first = box.tick()
        rels.append(release("0.23.5"))
        p, second = box.tick()
        self.assertEqual(p.action, "pin")
        old = box.gh.prs[first]
        self.assertEqual((old["state"], old["comment"]), ("closed", f"Superseded by #{second}: v0.23.5 is newer."))
        self.assertNotIn(old["ref"], box.gh.branches)
        lines = (box.repo / "CHANGELOG.md").read_text().split("### Changed\n\n", 1)[1].splitlines()[:2]
        self.assertTrue(lines[0].startswith("- Pin tycswap and its Windows tray to v0.23.5. Summary of 0.23.5."))
        self.assertTrue(lines[1].startswith("- tycswap v0.23.4, which the v0.23.5 pin includes: Summary of 0.23.4."))
        box.merge(second)
        self.assertEqual(box.tick()[0].action, "none")
        self.assertEqual(tp.read_pin(box.main_files["flake.nix"])["version"], "0.23.5")
        self.assertEqual(box.gh.open(), [])

    def test_a_pull_request_behind_main_is_replaced(self):
        box = Box(self, [release("0.23.4")])
        _, first = box.tick()
        box.gh.main = NEXT_MAIN
        p, second = box.tick()
        self.assertEqual(p.action, "pin")
        self.assertEqual(box.gh.prs[first]["comment"], f"Superseded by #{second}: main moved on.")
        self.assertEqual(box.gh.prs[second]["ref"], f"tycswap-pin/v0.23.4-{NEXT_MAIN[:8]}")

    def test_pull_requests_the_workflow_closed_do_not_hold_the_release(self):
        box = Box(self, [release("0.23.4")])
        _, first = box.tick()
        box.gh.main = NEXT_MAIN
        _, second = box.tick()
        box.gh.main = "3333333333333333333333333333333333333333"
        p, third = box.tick()
        self.assertEqual(p.action, "pin")
        self.assertEqual(box.gh.prs[second]["comment"], f"Superseded by #{third}: main moved on.")
        self.assertEqual([n for n, pr in box.gh.prs.items() if pr["state"] == "open"], [third])
        self.assertNotIn(first, (second, third))

    def test_a_release_without_its_windows_line_waits(self):
        for rel in (release("0.23.4", exe=False), release("0.23.4", sums=False)):
            box = Box(self, [release("0.23.3"), rel])
            p, number = box.tick()
            self.assertEqual((p.action, number), ("none", None))
            self.assertIn("no tycswap_v0.23.4_windows_amd64.exe line", p.reason)

    def test_drafts_prereleases_and_odd_tags_are_not_pinned(self):
        rels = [release("0.23.3"), release("0.23.4", draft=True), release("0.23.5", prerelease=True), dict(release("0.23.6"), tag_name="v0.23.6-rc1")]
        self.assertEqual(Box(self, rels).tick()[0].action, "none")

    def test_a_sums_line_that_disagrees_with_githubs_digest_is_refused(self):
        rel = release("0.23.4")
        rel["assets"][1]["hex"] = "f" * 64
        with self.assertRaisesRegex(tp.PinError, "GitHub's digest"):
            Box(self, [rel]).tick()

    def test_a_pin_merged_by_hand_closes_the_bot_pull_request(self):
        box = Box(self, [release("0.23.4")])
        _, number = box.tick()
        box.main_files["flake.nix"] = tp.write_pin(box.main_files["flake.nix"], {"version": "0.23.4"})
        p, _ = box.tick()
        self.assertEqual(p.action, "close")
        self.assertEqual(box.gh.prs[number]["comment"], "Closed by the tycswap pin workflow: main already pins v0.23.4.")

    def test_a_pull_request_closed_by_hand_holds_its_release(self):
        box = Box(self, [release("0.23.4")])
        _, number = box.tick()
        box.gh.prs[number].update(state="closed", closed_by="someone")
        p, again = box.tick()
        self.assertEqual((p.action, again), ("none", None))
        self.assertEqual(p.reason, f"v0.23.4 is held: #{number} was closed by hand; reopen it or pin by hand to take it")

    def test_a_reverted_pin_holds_its_release_and_the_next_one_is_pinned(self):
        rels = [release("0.23.4")]
        box = Box(self, rels)
        before = box.main_files["flake.nix"]
        _, number = box.tick()
        self.assertIn("reverting its pin after the merge, holds v0.23.4", box.gh.prs[number]["body"])
        box.merge(number)
        box.main_files["flake.nix"] = before
        p, again = box.tick()
        self.assertEqual((p.action, again), ("none", None))
        self.assertEqual(p.reason, f"v0.23.4 is held: its pin #{number} was merged and main pins v0.23.3 again; pin it by hand to take it")
        rels.append(release("0.23.5"))
        p, newer = box.tick()
        self.assertEqual(p.action, "pin")
        self.assertTrue(box.gh.prs[newer]["ref"].startswith("tycswap-pin/v0.23.5-"))

    def test_the_newest_release_is_chosen_by_number_not_by_text(self):
        box = Box(self, [release("0.23.10"), release("0.23.9")], pinned="0.23.8")
        p, number = box.tick()
        self.assertEqual(p.target.version, "0.23.10")

    def test_a_sums_file_without_the_exe_line_waits(self):
        box = Box(self, [release("0.23.4", sums_line=False)])
        p, number = box.tick()
        self.assertEqual((p.action, number), ("none", None))
        self.assertEqual(box.git.pushes, 0)

    def test_empty_release_notes_leave_the_line_without_a_summary(self):
        box = Box(self, [release("0.23.4", body="")])
        _, number = box.tick()
        url = "https://github.com/tyclab/tycswap/releases/tag/v0.23.4"
        top = (box.repo / "CHANGELOG.md").read_text().split("### Changed\n\n", 1)[1].splitlines()[0]
        self.assertEqual(top, f"- Pin tycswap and its Windows tray to v0.23.4. ([release notes]({url}))")
        self.assertIn(f"**[v0.23.4]({url})**\n", box.gh.prs[number]["body"])

    def test_notes_that_open_with_a_list_give_the_first_item(self):
        box = Box(self, [release("0.23.4", body="- **Fixed: x.** It waited.\n- **Second.** Other.\n")])
        box.tick()
        top = (box.repo / "CHANGELOG.md").read_text().split("### Changed\n\n", 1)[1].splitlines()[0]
        self.assertTrue(top.startswith("- Pin tycswap and its Windows tray to v0.23.4. **Fixed: x.** It waited. ([release"))

    def test_the_source_hash_starts_from_a_placeholder_not_the_old_value(self):
        # The old source is in this store: built under its hash, it would pass as the new release.
        box = Box(self, [release("0.23.4")])
        box.tick()
        self.assertEqual(box.nix.src_builds[0], tp.FAKE_HASH)
        self.assertEqual(tp.read_pin((box.repo / "flake.nix").read_text())["src"], box.truth["src"])

    def test_a_flake_that_evaluates_to_other_values_publishes_nothing(self):
        box = Box(self, [release("0.23.4")])
        box.nix.evaluates = dict(box.main_pin, version="0.23.4")
        with self.assertRaisesRegex(tp.PinError, "evaluates to"):
            box.tick()
        self.assertEqual((box.gh.prs, box.git.pushes), ({}, 0))

    def test_a_mismatch_of_another_derivation_is_not_taken_for_this_one(self):
        box = Box(self, [release("0.23.4")])
        box.nix.misreport["packages.x86_64-linux.tycswap.src"] = "tycswap-0.23.4-go-modules"
        with self.assertRaisesRegex(tp.PinError, "did not fetch"):
            box.tick()
        self.assertEqual(box.git.pushes, 0)
        box = Box(self, [release("0.23.4")])
        box.nix.misreport["packages.x86_64-linux.tycswap.goModules"] = "source"
        _, number = box.tick()
        self.assertIn("This pin does not build (packages.x86_64-linux.tycswap.goModules)", box.gh.prs[number]["body"])
        self.assertEqual(tp.read_pin((box.repo / "flake.nix").read_text())["vendor"], box.main_pin["vendor"])

    def test_every_failed_step_is_finished_by_the_next_run(self):
        for step in ("create_pr", "close_pr", "arm_automerge", "approve"):
            with self.subTest(step=step):
                rels = [release("0.23.4")]
                box = Box(self, rels)
                box.tick()
                rels.append(release("0.23.5"))
                box.gh.fail.add(step)
                with self.assertRaises(tp.PinError):
                    box.tick()
                box.tick()
                self.assertEqual(box.tick()[0].action, "none")
                (pr,) = box.gh.open()
                self.assertTrue(pr["ref"].startswith("tycswap-pin/v0.23.5-") and pr["armed"])
                self.assertEqual(box.gh.approved.count(box.gh.run_of(pr["number"])["id"]), 1)

    def test_a_pin_that_does_not_build_opens_a_failing_pull_request(self):
        box = Box(self, [release("0.23.4")])
        box.nix.broken.add("checks.x86_64-linux.tycswap")
        _, number = box.tick()
        body = box.gh.prs[number]["body"]
        self.assertIn("This pin does not build (checks.tycswap and checks.tycswap-windows)", body)
        self.assertIn("failed with exit code 1", body)
        self.assertTrue(box.gh.prs[number]["armed"])
        self.assertEqual(box.tick()[0].action, "none")

    def test_a_changelog_that_fails_lint_is_named_on_the_pull_request(self):
        box = Box(self, [release("0.23.4")])
        box.nix.broken.add("lint")
        _, number = box.tick()
        self.assertIn("This pin does not build (lint of CHANGELOG.md)", box.gh.prs[number]["body"])

    def test_one_failed_download_is_retried(self):
        box = Box(self, [release("0.23.4")])
        box.nix.flaky.add("packages.x86_64-linux.tycswap.src")
        _, number = box.tick()
        self.assertNotIn("does not build", box.gh.prs[number]["body"])

    def test_a_source_that_does_not_fetch_publishes_nothing(self):
        box = Box(self, [release("0.23.4")])
        box.nix.broken.add("packages.x86_64-linux.tycswap.src")
        with self.assertRaisesRegex(tp.PinError, "did not fetch"):
            box.tick()
        self.assertEqual((box.gh.prs, box.git.pushes), ({}, 0))


class CIRunTests(unittest.TestCase):
    """GitHub holds the CI run of a pull request the workflow's token opened until it is approved; the workflow approves it."""

    def writes(self, box):
        return [c for c in box.gh.calls if c != "asset_text"]

    def test_the_held_run_is_approved_after_the_pull_request_is_opened_and_armed(self):
        box = Box(self, [release("0.23.4")])
        _, number = box.tick()
        run = box.gh.run_of(number)
        self.assertEqual(self.writes(box), ["create_pr", "arm_automerge", "approve"])
        self.assertEqual((box.gh.approved, run["status"]), ([run["id"]], "queued"))
        self.assertEqual(box.ci, f"approved CI run {run['id']}")

    def test_a_run_github_creates_late_is_waited_for(self):
        box = Box(self, [release("0.23.4")])
        box.gh.run_delay = tp.RUN_WAIT - 1
        start = box.gh.clock + 900
        _, number = box.tick()
        self.assertEqual(box.gh.approved, [box.gh.run_of(number)["id"]])
        self.assertGreaterEqual(box.gh.clock - start, tp.RUN_WAIT - 1)
        self.assertLessEqual(box.gh.clock - start, tp.RUN_WAIT)

    def test_a_pull_request_whose_run_was_approved_or_ran_is_left_alone(self):
        for state in ({}, {"status": "in_progress"}, {"status": "completed", "conclusion": "success"},
                      {"status": "completed", "conclusion": "failure"}):  # fmt: skip
            with self.subTest(state=state):
                box = Box(self, [release("0.23.4")])
                _, number = box.tick()
                box.gh.run_of(number).update(state)
                box.gh.prs[number]["armed"] = False
                p, _ = box.tick()
                self.assertEqual((p.action, p.reason), ("none", f"#{number} pins v0.23.4 on the current main"))
                self.assertEqual((len(box.gh.approved), box.gh.prs[number]["armed"]), (1, False))

    def test_a_run_a_person_approved_before_the_next_run_is_left_alone(self):
        box = Box(self, [release("0.23.4")])
        box.gh.run_delay = tp.RUN_WAIT + 1
        _, number = box.tick()
        box.gh.run_of(number).update(status="queued", conclusion=None)
        self.assertEqual(box.tick()[0].action, "none")
        self.assertEqual(box.gh.approved, [])

    def test_a_run_the_first_run_did_not_find_is_approved_by_the_next(self):
        box = Box(self, [release("0.23.4")])
        box.gh.run_delay = tp.RUN_WAIT + 1
        _, number = box.tick()
        self.assertEqual((box.gh.approved, box.gh.prs[number]["armed"]), ([], True))
        self.assertEqual(box.ci, f"GitHub created no CI run within {tp.RUN_WAIT} s, the next run approves it")
        p, again = box.tick()
        self.assertEqual((p.action, p.reason, again), ("finish", f"#{number}'s CI run waits for approval", None))
        self.assertEqual(box.gh.approved, [box.gh.run_of(number)["id"]])
        self.assertEqual(box.ci, f"approved CI run {box.gh.run_of(number)['id']}")
        self.assertEqual(box.tick()[0].action, "none")

    def test_a_run_that_starts_without_approval_is_not_approved(self):
        box = Box(self, [release("0.23.4")])
        box.gh.held = False
        box.tick()
        self.assertEqual((box.gh.approved, box.ci), ([], "its CI run needed no approval"))
        self.assertEqual(box.tick()[0].action, "none")

    def test_a_pull_request_github_created_no_run_for_says_so(self):
        box = Box(self, [release("0.23.4")])
        box.gh.run_delay = None
        _, number = box.tick()
        p, _ = box.tick()
        self.assertEqual((p.action, p.reason), ("none", f"#{number} pins v0.23.4; GitHub has not created its CI run yet"))

    def test_a_refused_approval_fails_the_run_and_says_what_a_person_does(self):
        box = Box(self, [release("0.23.4")])
        box.gh.refuse = "gh: Resource not accessible by integration (HTTP 403)"
        rc, out, err = box.act_step()
        (pr,) = box.gh.open()
        number, run = pr["number"], box.gh.run_of(pr["number"])
        self.assertEqual((rc, out), (1, ""))
        self.assertIn(f"approving CI run {run['id']} of #{number} failed: ", err)
        self.assertIn("gh: Resource not accessible by integration (HTTP 403)", err)
        self.assertIn(f'A person approves the run with "Approve workflows to run" on #{number}', err)
        self.assertIn("until this workflow has a token that may approve the run", err)
        self.assertTrue(pr["armed"])
        # Every run fails the same way while the run waits; once a person approved it, the pull request is left alone.
        self.assertEqual(box.act_step()[0], 1)
        run.update(status="queued", conclusion=None)
        rc, out, err = box.act_step()
        self.assertEqual((rc, err, box.gh.approved), (0, "", []))
        self.assertEqual(out, f"none: #{number} pins v0.23.4 on the current main\n")

    def test_the_act_step_names_the_pull_request_and_its_approved_run(self):
        box = Box(self, [release("0.23.4")])
        rc, out, _ = box.act_step()
        (pr,) = box.gh.open()
        run_id = box.gh.run_of(pr["number"])["id"]
        self.assertEqual((rc, out), (0, f"pin: main pins v0.23.3, v0.23.4 is out; opened #{pr['number']}; approved CI run {run_id}\n"))


class ForeignPullRequestTests(unittest.TestCase):
    """A pull request the workflow did not open is never kept, armed, approved or closed, whatever its branch is called."""

    FOREIGN = {
        "fork": {"repo": "someone/flakelab"},
        "deleted fork": {"repo": None},
        # Isolates the repository guard: GitHub gives no fork pull request the workflow's bot as author.
        "fork, bot as author": {"repo": "someone/flakelab", "author": tp.BOT_LOGIN},
        "same repository, opened by a person": {"author": "someone"},
    }

    def assertUntouched(self, box, number):
        pr, run = box.gh.prs[number], box.gh.run_of(number)
        self.assertEqual((pr["state"], pr["armed"], pr.get("comment"), run["conclusion"]), ("open", False, None, "action_required"))
        self.assertNotIn(run["id"], box.gh.approved)

    def test_one_named_like_the_newest_pin_is_not_kept_or_finished(self):
        for name, fields in self.FOREIGN.items():
            with self.subTest(name):
                box = Box(self, [release("0.23.4")])
                foreign = box.gh.add_pr("tycswap-pin/v0.23.4-abcdef12", **fields)
                p, number = box.tick()
                self.assertEqual(p.action, "pin")
                self.assertNotEqual(number, foreign)
                self.assertUntouched(box, foreign)

    def test_one_named_like_an_older_pin_is_not_superseded(self):
        for name, fields in self.FOREIGN.items():
            with self.subTest(name):
                box = Box(self, [release("0.23.4"), release("0.23.5")])
                foreign = box.gh.add_pr(f"tycswap-pin/v0.23.4-{MAIN[:8]}", **fields)
                self.assertEqual(box.tick()[0].action, "pin")
                self.assertUntouched(box, foreign)

    def test_a_branch_name_held_by_a_persons_pull_request_is_not_pushed(self):
        box = Box(self, [release("0.23.4")])
        foreign = box.gh.add_pr(f"tycswap-pin/v0.23.4-{MAIN[:8]}", author="someone")
        p, number = box.tick()
        self.assertEqual((p.action, number, box.git.pushes), ("none", None, 0))
        self.assertIn(f"is the head of #{foreign}, which the workflow did not open", p.reason)
        self.assertUntouched(box, foreign)

    def test_one_named_like_the_pinned_release_is_not_closed(self):
        for name, fields in self.FOREIGN.items():
            with self.subTest(name):
                box = Box(self, [release("0.23.4")], pinned="0.23.4")
                foreign = box.gh.add_pr(f"tycswap-pin/v0.23.4-{MAIN[:8]}", **fields)
                self.assertEqual(box.tick()[0].action, "none")
                self.assertUntouched(box, foreign)


@unittest.skipUnless(os.environ.get("FLAKELAB_TYCSWAP_PIN_LIVE") == "1", "FLAKELAB_TYCSWAP_PIN_LIVE=1 runs the real releases")
class LiveTests(unittest.TestCase):
    """Real GitHub and nix: main before each by-hand pin, moved to that release, must equal the by-hand commit."""

    def test_real_releases_reproduce_the_hand_pins(self):
        # v0.20.0 changed go.mod, so its vendorHash differs from v0.19.0's.
        for version, pin_commit in (("0.23.2", "c69fb76"), ("0.23.3", "3a3fbf0"), ("0.20.0", "f5651bd")):
            with self.subTest(version=version), tempfile.TemporaryDirectory() as tmp:
                archive = subprocess.run(["git", "-C", str(ROOT), "archive", f"{pin_commit}^"], capture_output=True, check=True).stdout
                subprocess.run(["tar", "-x", "-C", tmp], input=archive, check=True)
                gh = tp.GitHub(REPO)
                (rel,) = tp.published([gh.api(f"repos/{tp.UPSTREAM}/releases/tags/v{version}")])
                self.assertTrue(tp.ready(gh, rel))
                values, failure = tp.compute(Path(tmp), tp.Nix(Path(tmp), f"path:{tmp}"), rel)
                by_hand = tp.read_pin(subprocess.run(["git", "-C", str(ROOT), "show", f"{pin_commit}:flake.nix"], capture_output=True, text=True, check=True).stdout)
                print(f"\nv{version}: computed {values}\n         by hand  {by_hand}")
                self.assertIsNone(failure)
                self.assertEqual(values, by_hand)


if __name__ == "__main__":
    unittest.main(verbosity=2)
