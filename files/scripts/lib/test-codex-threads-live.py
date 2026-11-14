#!/usr/bin/env python3
"""Live checks for Codex lanes: `flakelab sessions` (files/scripts/claude-sessions) and
lib/codex_threads.py against this box's own Codex server.

    FLAKELAB_CODEX_LIVE=1 files/scripts/test-codex-threads

Never part of `make test` or the flake check: they start real sessions and spend a
little of the account's usage (three short turns). Run them on a box with Codex, and
again after a Codex update: the offline suite replays answers recorded from one
version, and only this file asks the server that is really installed.

  FLAKELAB_CODEX_LIVE_MODEL   the model to use (default: the server's default model);
                              name a cheap one. Its lowest effort is used.
  FLAKELAB_STATE_ROOT         flakelab's state root, if the box has one: the state sync
                              copies rollouts there and pulls a deleted one back, so
                              the copy of each test session is removed too.

Every check works in a folder of its own and in a tmux session of its own
(flakelab-live-<pid>), never in `agents`. The ids it creates are recorded and removed
in a step that runs whatever happened before; a removal that fails is reported with
what is left. Trust is compared per folder, not by comparing the whole of config.toml,
which other sessions may change meanwhile.
"""

import glob
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

HERE = Path(__file__).parent
SESSIONS = HERE.parent / "claude-sessions"
spec = importlib.util.spec_from_file_location("codex_threads", HERE / "codex_threads.py")
assert spec and spec.loader
codex_threads = importlib.util.module_from_spec(spec)
spec.loader.exec_module(codex_threads)

TMUX_SESSION = f"flakelab-live-{os.getpid()}"
CODEX_HOME = os.environ.get("CODEX_HOME") or os.path.expanduser("~/.codex")
OK_PROMPT = "Reply with the single word OK and do nothing else."
SLEEP = "sleep 240"
SLEEP_PROMPT = f"Run the shell command '{SLEEP}' in the foreground and then reply with the single word OK."
LEFT = []  # what a cleanup could not remove


def server(experimental=False):
    return codex_threads.Server(experimental=experimental)


def call(method, params, experimental=False):
    s = server(experimental)
    try:
        return s.call(method, params)
    finally:
        s.close()


def helper(*args):
    done = subprocess.run([sys.executable, str(HERE / "codex_threads.py"), *args], capture_output=True, text=True, timeout=120)
    return done.returncode, (json.loads(done.stdout) if done.stdout.strip() else None), done.stderr


def sessions(*args):
    env = {**os.environ, "FLAKELAB_TMUX_SESSION": TMUX_SESSION}
    done = subprocess.run([str(SESSIONS), *args], capture_output=True, text=True, timeout=300, env=env, stdin=subprocess.DEVNULL)
    return done.returncode, done.stdout, done.stderr


def windows():
    done = subprocess.run(["tmux", "list-windows", "-t", TMUX_SESSION, "-F", "#{window_name} #{@flakelab_session}"], capture_output=True, text=True)
    found: dict[str, str] = {}
    for line in done.stdout.splitlines():
        name, _, recorded = line.partition(" ")
        found[name] = recorded
    return found


def trust_entries(folder):
    s = server()
    try:
        _, projects = codex_threads.projects_of(s, str(folder))
    finally:
        s.close()
    real = os.path.realpath(folder)
    return sorted(k for k in projects if os.path.realpath(k) == real or os.path.realpath(k).startswith(real + "/"))


def state(tid):
    rc, out, err = helper("state", tid)
    assert rc == 0 and out, err
    return out[0]


def wait_for(what, check, seconds):
    end = time.monotonic() + seconds
    while True:
        value = check()
        if value:
            return value
        if time.monotonic() > end:
            raise AssertionError(f"after {seconds} s still not: {what}")
        time.sleep(2)


class Live(unittest.TestCase):
    model = effort = ""
    defaults = (None, None)

    @classmethod
    def setUpClass(cls):
        s = server()
        try:
            config, _ = codex_threads.projects_of(s, os.getcwd())
            models = s.pages("model/list", {"includeHidden": True})
        finally:
            s.close()
        entry = codex_threads.resolve_model(models, os.environ.get("FLAKELAB_CODEX_LIVE_MODEL"), config.get("model"))
        cls.model = entry["model"]
        cls.effort = [e["reasoningEffort"] if isinstance(e, dict) else e for e in entry["supportedReasoningEfforts"]][0]
        cls.defaults = (config.get("model"), config.get("model_reasoning_effort"))
        print(f"live checks on {cls.model} {cls.effort}, Codex server {s.version}, tmux session {TMUX_SESSION}", file=sys.stderr)

    @classmethod
    def tearDownClass(cls):
        subprocess.run(["tmux", "kill-session", "-t", TMUX_SESSION], capture_output=True)

    def setUp(self):
        self.folder = Path(tempfile.mkdtemp(prefix="flakelab-live-")).resolve()
        self.addCleanup(shutil.rmtree, self.folder, True)

    def remove(self, tid):
        """Stop and delete a test session, and its copy under the state root."""
        rc, _, err = helper("stop", tid)
        if rc:
            LEFT.append(f"session {tid} could not be stopped: {err.strip()}")
        try:
            call("thread/delete", {"threadId": tid})
        except codex_threads.Refusal as err:
            LEFT.append(f"session {tid}: {err}")
        homes = [os.environ.get("FLAKELAB_STATE_ROOT") and os.path.join(os.environ["FLAKELAB_STATE_ROOT"], "codex"), CODEX_HOME]
        for home in filter(None, homes):
            for path in glob.glob(os.path.join(home, "*sessions", "**", f"rollout-*-{tid}.jsonl*"), recursive=True):
                try:
                    os.unlink(path)
                except OSError as err:
                    LEFT.append(f"{path}: {err}")

    def start(self, name, prompt, *more):
        rc, _, err = sessions("--start", "codex", str(self.folder), "--model", self.model, "--effort", self.effort, "--name", name, "--prompt", prompt, "--detach", *more)
        found = re.search(r"session ([0-9a-f-]{36})", err) or re.search(r"codex resume ([0-9a-f-]{36})", err)
        tid = found.group(1) if found else ""
        if tid:
            self.addCleanup(self.remove, tid)
        # A start that fails without naming a session created at most an empty conversation,
        # which leaves no file: there is nothing to remove then.
        self.assertEqual(rc, 0, err)
        self.assertTrue(tid, err)
        return tid

    def test_L1_a_lane_runs_on_its_model_and_effort_and_closes(self):
        """G1, G2, G4, G5."""
        # A folder without .git or .codex: no trust decision exists, and Codex saves none.
        tid = self.start("live-l1", OK_PROMPT, "--trust")
        self.assertEqual(windows().get("live-l1"), tid, "the window exists and records the session")
        wait_for("the first turn finished", lambda: state(tid)["state"] == "idle", 180)
        # After the window attached: its client must not have reset model or effort.
        now = state(tid)
        self.assertEqual((now["model"], now["effort"]), (self.model, self.effort))
        # The one place a rollout is read: what the turn really ran with.
        rollout = glob.glob(os.path.join(CODEX_HOME, "sessions", "**", f"rollout-*-{tid}.jsonl"), recursive=True)
        self.assertEqual(len(rollout), 1)
        turns = [json.loads(line)["payload"] for line in open(rollout[0], encoding="utf-8") if '"turn_context"' in line[:80]]
        self.assertTrue(turns)
        self.assertEqual({(t.get("model"), t.get("effort")) for t in turns}, {(self.model, self.effort)})
        # The table ties the window to its session and reads its state from the server.
        rc, out, err = sessions("--json")
        rows = [r for r in json.loads(out) if (r.get("host") or {}).get("window") == "live-l1"]
        self.assertEqual([(r["session"], r["state"], r["model"], r["effort"]) for r in rows], [(tid, "idle", self.model, self.effort)], err)
        # The defaults are what they were, and no trust entry appeared for the folder.
        s = server()
        config, _ = codex_threads.projects_of(s, str(self.folder))
        s.close()
        self.assertEqual((config.get("model"), config.get("model_reasoning_effort")), self.defaults)
        self.assertEqual(trust_entries(self.folder), [])
        # Refusals create nothing.
        for flags in (("--model", "no-such-model-x"), ("--model", self.model, "--effort", "no-such-effort")):
            rc, _, err = sessions("--start", "codex", str(self.folder), *flags, "--prompt", OK_PROMPT, "--trust", "--detach")
            self.assertEqual(rc, 2, err)
        self.assertEqual(sorted(windows()), ["live-l1"])
        # Finished: it closes, and names what reopens it.
        rc, out, err = sessions("--close", "live-l1")
        self.assertEqual(rc, 0, err)
        self.assertIn(f"codex resume {tid}", out)
        self.assertNotIn("live-l1", windows())

    def test_L2_a_folder_without_a_trust_decision_is_refused(self):
        """G3."""
        subprocess.run(["git", "init", "-q", str(self.folder)], check=True)
        rc, _, err = sessions("--start", "codex", str(self.folder), "--model", self.model, "--effort", self.effort, "--prompt", OK_PROMPT, "--detach")
        self.assertEqual(rc, 1, err)
        self.assertIn("--trust", err)
        self.assertEqual(trust_entries(self.folder), [], "Codex saved no trust entry for the folder")
        self.assertEqual(windows(), {})

    def test_L3_close_refuses_running_work_and_force_stops_it(self):
        """G5."""
        tid = self.start("live-l3", SLEEP_PROMPT, "--trust")

        def running():
            return [t for t in call("thread/backgroundTerminals/list", {"threadId": tid}, experimental=True)["data"] if SLEEP in str(t.get("command"))]

        # The terminal list naming the command proves it started; a process search would not.
        wait_for(f"the session runs {SLEEP}", running, 120)
        rc, out, err = sessions("--close", "live-l3")
        self.assertEqual((rc, out), (1, ""), err)
        self.assertIn("not closed", err)
        self.assertIn("live-l3", windows())
        rc, out, err = sessions("--close", "--force", "live-l3")
        self.assertEqual(rc, 0, err)
        self.assertEqual(running(), [])
        self.assertEqual(state(tid)["state"], "idle")
        self.assertNotIn("live-l3", windows())
        self.assertIn(f"codex resume {tid}", out)


    def test_L4_close_removes_only_a_window_that_still_is_the_lane(self):
        """Window safety on a real tmux: its pane count and its report of the start command."""
        tid = self.start("live-l4", OK_PROMPT, "--trust")
        wait_for("the first turn finished", lambda: state(tid)["state"] == "idle", 180)
        target = f"{TMUX_SESSION}:live-l4"

        def tmux(*args):
            return subprocess.run(["tmux", *args], capture_output=True, text=True)

        # Another window that carries the same mark and holds the words, and is no lane.
        tmux("new-window", "-d", "-t", f"{TMUX_SESSION}:", "-n", "live-fake", f"sh -c 'echo resume {tid}; sleep 120'")
        tmux("set-option", "-w", "-t", f"{TMUX_SESSION}:live-fake", "@flakelab_session", tid)
        rc, out, err = sessions("--close", "live-fake")
        self.assertEqual((rc, out), (1, ""), err)
        self.assertIn("was not started by flakelab", err)
        self.assertIn("live-fake", windows())
        tmux("kill-window", "-t", f"{TMUX_SESSION}:live-fake")
        # The lane itself, split: two panes are not what flakelab started.
        tmux("split-window", "-d", "-t", target, "sleep 120")
        rc, out, err = sessions("--close", "live-l4")
        self.assertEqual((rc, out), (1, ""), err)
        self.assertIn("has 2 panes", err)
        self.assertIn("live-l4", windows())
        extra = [line.split(" ", 1)[0] for line in tmux("list-panes", "-t", target, "-F", "#{pane_id} #{pane_start_command}").stdout.splitlines() if "sleep 120" in line]
        self.assertEqual(len(extra), 1)
        tmux("kill-pane", "-t", extra[0])
        # One pane again, with the start command as tmux reports it: now it goes.
        rc, out, err = sessions("--close", "live-l4")
        self.assertEqual(rc, 0, err)
        self.assertNotIn("live-l4", windows())
        self.assertIn(f"codex resume {tid}", out)


def main():
    for tool in ("tmux", "codex", "git", "jq"):
        if not shutil.which(tool):
            print(f"Error: the live checks need {tool} on PATH", file=sys.stderr)
            return 2
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(Live))
    if LEFT:
        print("LEFT BEHIND by the cleanup:", *LEFT, sep="\n  ", file=sys.stderr)
    return 0 if result.wasSuccessful() and not LEFT else 1
