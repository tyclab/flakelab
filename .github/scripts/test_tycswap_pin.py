"""tycswap_pin against a fake release list, fake pull requests and a fake nix; FLAKELAB_TYCSWAP_PIN_LIVE=1 adds the real releases."""

import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

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


def release(version, body=None, exe=True, sums=True, draft=False, prerelease=False):
    hex_digest = hex_for(version)
    assets = []
    if exe:
        assets.append({"id": f"exe-{version}", "name": tp.windows_asset(version), "state": "uploaded", "digest": f"sha256:{hex_digest}"})
    if sums:
        assets.append({"id": f"sums-{version}", "name": "SHA256SUMS", "state": "uploaded", "hex": hex_digest})
    return {
        "tag_name": f"v{version}",
        "html_url": f"https://github.com/tyclab/tycswap/releases/tag/v{version}",
        "body": body if body is not None else f"Summary of {version}.\nSecond line.\n\n- **Detail.** More.\n",
        "draft": draft,
        "prerelease": prerelease,
        "assets": assets,
    }


class FakeGitHub(tp.GitHub):
    """The read paths go through the real GitHub methods; `api` answers from this model."""

    def __init__(self, releases):
        super().__init__(REPO)
        self.release_list, self.main = releases, MAIN
        self.prs, self.runs, self.branches, self.calls = {}, {}, {}, []
        self.number, self.fail = 500, set()

    def _maybe_fail(self, name):
        self.calls.append(name)
        if name in self.fail:
            self.fail.discard(name)
            raise tp.PinError(f"injected failure in {name}")

    def api(self, path, *args):
        if path.startswith(f"repos/{tp.UPSTREAM}/releases?"):
            return self.release_list
        if m := re.match(rf"repos/{REPO}/pulls\?state=(\w+)", path):
            return [self._raw(p) for p in sorted(self.prs.values(), key=lambda p: -p["number"]) if p["state"] == m[1]]
        if m := re.match(rf"repos/{REPO}/issues/(\d+)$", path):
            return {"closed_by": {"login": self.prs[int(m[1])]["closed_by"]}}
        if m := re.match(rf"repos/{REPO}/compare/(\w+)\.\.\.(\w+)$", path):
            base = next(p["base"] for p in self.prs.values() if p["sha"] == m[2])
            return {"behind_by": 0 if base == m[1] else 1}
        if m := re.match(rf"repos/{REPO}/actions/workflows/ci.yml/runs\?head_sha=(\w+)$", path):
            waiting = [{"event": "pull_request", "status": "completed", "conclusion": "action_required"}]
            return {"workflow_runs": waiting + [{"event": "workflow_dispatch", "status": "queued", "conclusion": None}] * self.runs.get(m[1], 0)}
        raise AssertionError(f"unexpected api path {path}")

    def _raw(self, p):
        head = {"ref": p["ref"], "sha": p["sha"], "repo": {"full_name": REPO}}
        return {"number": p["number"], "head": head, "auto_merge": {"merge_method": "merge"} if p["armed"] else None, "merged_at": None}

    def asset_text(self, asset):
        self.calls.append("asset_text")
        rel = next(r for r in self.release_list if asset in r["assets"])
        version = rel["tag_name"][1:]
        return f"{'0' * 64}  tycswap_v{version}_linux_amd64\n{asset['hex']}  {tp.windows_asset(version)}\n"

    def create_pr(self, branch, title, body):
        self._maybe_fail("create_pr")
        self.number += 1
        sha, base = self.branches[branch]
        self.prs[self.number] = dict(number=self.number, ref=branch, sha=sha, base=base, state="open", armed=False, title=title, body=body, closed_by=None)
        return self.number

    def close_pr(self, number, comment):
        self._maybe_fail("close_pr")
        self.prs[number].update(state="closed", closed_by=tp.BOT_LOGIN, comment=comment)
        self.branches.pop(self.prs[number]["ref"], None)

    def arm_automerge(self, number):
        self._maybe_fail("arm_automerge")
        self.prs[number]["armed"] = True

    def dispatch_ci(self, branch):
        self._maybe_fail("dispatch_ci")
        sha = self.branches[branch][0]
        self.runs[sha] = self.runs.get(sha, 0) + 1

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


class FakeNix:
    """Answers like nix for the pin in flake.nix: a mismatch names the true hash."""

    def __init__(self, repo, truth):
        self.repo, self.truth, self.builds = repo, truth, []
        self.broken, self.flaky = set(), set()

    def build(self, *attrs):
        self.builds.append(attrs)
        pin = tp.read_pin((self.repo / "flake.nix").read_text())
        for attr in attrs:
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
                if pin[f] != self.truth[f]:
                    return False, (
                        f"error: hash mismatch in fixed-output derivation '/nix/store/abc-{d}.drv':\n"
                        f"         specified: {pin[f]}\n            got:    {self.truth[f]}\n"
                    )
        return True, ""

    def pinned(self):
        return tp.read_pin((self.repo / "flake.nix").read_text())

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
        self.main_files = {n: (self.repo / n).read_text() for n in ("flake.nix", "CHANGELOG.md")}

    def tick(self):
        """One workflow run: plan, then act on a fresh checkout of main."""
        for name, text in self.main_files.items():
            (self.repo / name).write_text(text)
        pinned = tp.read_pin((self.repo / "flake.nix").read_text())["version"]
        p = tp.plan(pinned, self.gh, self.git.head())
        if p.target:
            self.truth["windows"] = tp.sri(p.target.windows_hex)
        number = tp.act(p, self.repo, self.gh, self.nix, self.git, self.git.head(), "https://example.invalid/run")
        return p, number

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

    def test_first_paragraph(self):
        self.assertEqual(tp.first_paragraph("# Title\r\n\r\nOne\r\ntwo.\r\n\r\nRest"), "One two.")
        self.assertEqual(tp.first_paragraph(""), "")

    def test_changelog_gets_a_changed_section_where_keep_a_changelog_puts_it(self):
        text = "# Changelog\n\n## [Unreleased]\n\n### Added\n\n- a\n\n### Fixed\n\n- f\n\n## [1.0.0]\n"
        out = tp.add_changelog(text, ["- pin"])
        self.assertIn("### Added\n\n- a\n\n### Changed\n\n- pin\n\n### Fixed", out)

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
        self.assertEqual(box.gh.runs, {pr["sha"]: 1})
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
        self.assertIn(f"#{number} was closed by hand", p.reason)

    def test_every_failed_step_is_finished_by_the_next_run(self):
        for step in ("create_pr", "close_pr", "arm_automerge", "dispatch_ci"):
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
                self.assertEqual(box.gh.runs[pr["sha"]], 1)

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
