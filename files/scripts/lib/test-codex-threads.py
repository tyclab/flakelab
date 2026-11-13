#!/usr/bin/env python3
"""Offline checks for codex_threads.py against codex_fake_server.py, a stand-in
whose answers come from exchanges recorded on a real Codex server; and, with
FLAKELAB_CODEX_LIVE=1, live checks against the box's own Codex server (see the
end of this file)."""

import base64
import importlib.util
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
import unittest

HERE = Path(__file__).parent
HELPER = HERE / "codex_threads.py"


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, HERE / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


fake_server = load("codex_fake_server", "codex_fake_server.py")
codex_threads = load("codex_threads", "codex_threads.py")
WIRE = json.loads((fake_server.DATA / "wire.json").read_text())

LUNA, SOL, ASTRA = "gpt-6-luna", "gpt-6.1-sol", "gpt-6-astra"
T1, T2, T3 = "11111111-1111-7111-8111-111111111111", "33333333-3333-7333-8333-333333333333", "44444444-4444-7444-8444-444444444444"


class Case(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.home = self.root / "codex-home"
        self.fake = fake_server.FakeCodex(self.home)
        self.addCleanup(self.fake.stop)
        self.lane = self.root / "lane"
        self.lane.mkdir()

    def run_helper(self, *args, stdin=b"", timeout=60, env=None):
        full = {**os.environ, "CODEX_HOME": str(self.home), **(env or {})}
        done = subprocess.run([sys.executable, str(HELPER), *map(str, args)], input=stdin, capture_output=True, timeout=timeout, env=full)
        out, err = done.stdout.decode(), done.stderr.decode()
        # A crash must never pass for a refusal: failures are one "Error: ..." line.
        self.assertNotIn("Traceback", err)
        if done.returncode:
            self.assertTrue(err.startswith("Error: "), err)
            self.assertEqual(err.count("\n"), 1, err)
        return done.returncode, (json.loads(out) if out.strip() else None), err

    def start(self, *args, stdin=b"Read BRIEF.md and do what it says.", **kw):
        return self.run_helper("start", "--cwd", self.lane, *args, stdin=stdin, **kw)

    def called(self, method):
        return [p for m, p in self.fake.log if m == method]

    def git(self, *args, cwd):
        subprocess.run(["git", "-c", "init.defaultBranch=main", "-c", "user.name=t", "-c", "user.email=t@example.invalid", *args], cwd=cwd, check=True, capture_output=True)


class FramesTest(unittest.TestCase):
    """U-frames. The handshake pair and the three frame headers are bytes a real server sent
    (wire.json); fragments, the ping, the close and the damaged frames are built here from the
    WebSocket layout, because the recording held none."""

    def reader(self, data):
        a, b = socket.socketpair()
        self.addCleanup(a.close)
        self.addCleanup(b.close)
        b.sendall(data)
        b.shutdown(socket.SHUT_WR)
        ws = codex_threads.WebSocket.__new__(codex_threads.WebSocket)
        ws.sock, ws.buffer = a, b""
        self.other = b
        return ws

    def payload(self, n):
        text = json.dumps({"id": 1, "result": {"pad": ""}})
        return (text[:-3] + "x" * (n - len(text)) + text[-3:]).encode()

    def test_the_recorded_handshake_pair_matches_the_computed_accept(self):
        recorded = [line.split(":", 1)[1].strip() for line in WIRE["handshake_answer"].split("\r\n") if line.lower().startswith("sec-websocket-accept")]
        # The recording used the nonce of RFC 6455's own example; the fixture keeps its text.
        key = base64.b64encode(WIRE["request_nonce_text"].encode()).decode()
        self.assertEqual([codex_threads.accept_for(key)], recorded)

    def test_recorded_headers_of_three_sizes_are_read(self):
        for name in ("short", "medium", "large"):
            n = WIRE[name]["payload_bytes"]
            ws = self.reader(bytes.fromhex(WIRE[name]["header_hex"]) + self.payload(n))
            self.assertEqual(len(ws.recv_text(codex_threads.Deadline(5))), n, name)

    def test_fragments_are_joined_and_a_ping_between_them_is_answered(self):
        body = self.payload(300)
        ws = self.reader(fake_server.frame(0x1, body[:100], fin=False) + fake_server.frame(0x9, b"hi") + fake_server.frame(0x0, body[100:]))
        self.assertEqual(ws.recv_text(codex_threads.Deadline(5)).encode(), body)
        pong = self.other.recv(64)
        self.assertEqual(pong[0], 0x8A)
        self.assertTrue(pong[1] & 0x80, "a client frame is masked")
        self.assertEqual(bytes(c ^ pong[2 + i % 4] for i, c in enumerate(pong[6:])), b"hi")

    def test_a_truncated_frame_a_close_and_an_oversized_message_end_the_read(self):
        whole = fake_server.frame(0x1, self.payload(300))
        for data, word in ((whole[:50], "closed"), (fake_server.frame(0x8, b""), "closed"), (bytes([0x81, 127]) + (17 * 1024 * 1024).to_bytes(8, "big"), "16 MiB")):
            with self.assertRaises(codex_threads.Refusal) as caught:
                self.reader(data).recv_text(codex_threads.Deadline(5))
            self.assertIn(word, str(caught.exception))


class PreflightTest(Case):
    """U-preflight: what the command needs is asked for before anything is changed."""

    def test_no_server_is_named_with_what_to_run(self):
        self.fake.stop()
        rc, out, err = self.start("--model", LUNA)
        self.assertEqual((rc, out), (1, None))
        self.assertIn("codex app-server daemon start", err)

    def test_a_wrong_accept_value_is_refused(self):
        self.fake.bad_accept = True
        rc, _, err = self.start("--model", LUNA)
        self.assertEqual(rc, 1)
        self.assertIn("handshake", err)

    def test_a_missing_method_or_field_stops_before_thread_start(self):
        for attr, value, word in (("unknown", {"model/list"}, "model/list"), ("fail", {"config/read": ["drop:config"]}, "config"), ("fail", {"model/list": ["drop:data"]}, "data")):
            self.fake.log.clear()
            self.fake.unknown, self.fake.fail = set(), {}
            setattr(self.fake, attr, value)
            self.fake.projects = {str(self.lane): "trusted"}
            rc, out, err = self.start("--model", LUNA)
            self.assertEqual((rc, out), (1, None), word)
            self.assertIn(word, err)
            self.assertIn("0.169.0", err, "the server's version is named")
            self.assertNotIn("thread/start", self.fake.methods())

    def test_answers_in_fragments_with_notifications_and_server_requests_between(self):
        self.fake.fragment = self.fake.noise = True
        self.fake.projects = {str(self.lane): "trusted"}
        rc, out, err = self.start("--model", LUNA, "--effort", "low")
        self.assertEqual(rc, 0, err)
        self.assertEqual(out["model"], LUNA)


class ValidateTest(Case):
    """U-validate (G2): a wrong model or effort creates nothing and lists what is offered."""

    def setUp(self):
        super().setUp()
        self.fake.projects = {str(self.lane): "trusted"}

    def refused(self, *args):
        rc, out, err = self.start(*args)
        self.assertEqual((rc, out), (2, None), err)
        self.assertNotIn("thread/start", self.fake.methods())
        return err

    def test_unknown_model_lists_the_models(self):
        err = self.refused("--model", "gpt-9-nope")
        for name in (SOL, ASTRA, LUNA):
            self.assertIn(name, err)

    def test_effort_the_model_lacks_lists_its_efforts(self):
        err = self.refused("--model", LUNA, "--effort", "ultra")
        self.assertIn("low, medium, high, xhigh, max", err)

    def test_a_spelling_two_models_share_is_refused_with_both(self):
        self.fake.models[0]["displayName"] = self.fake.models[1]["displayName"] = "Shared Name"
        err = self.refused("--model", "shared name")
        self.assertIn(self.fake.models[0]["id"], err)
        self.assertIn(self.fake.models[1]["id"], err)

    def test_model_by_display_name_and_without_case(self):
        rc, out, err = self.start("--model", "gpt-6-LUNA", "--effort", "LOW")
        self.assertEqual((rc, out["model"], out["effort"]), (0, LUNA, "low"), err)

    def test_defaults(self):
        cases = (
            ({"model": ASTRA, "model_reasoning_effort": "high"}, (), (ASTRA, "high")),
            ({"model": None, "model_reasoning_effort": None}, (), (SOL, "low")),  # the list's default model and its default effort
            ({"model": ASTRA, "model_reasoning_effort": "ultra"}, ("--model", LUNA), (LUNA, "medium")),  # luna has no ultra
            ({"model": ASTRA, "model_reasoning_effort": "high"}, ("--effort", "max"), (ASTRA, "max")),
        )
        for config, args, want in cases:
            self.fake.config = config
            rc, out, err = self.start(*args)
            self.assertEqual((rc, (out or {}).get("model"), (out or {}).get("effort")), (0, *want), f"{config} {args} {err}")

    def test_a_model_on_the_second_page_is_found(self):
        self.fake.page_size = 2
        rc, out, err = self.start("--model", LUNA)
        self.assertEqual((rc, out["model"]), (0, LUNA), err)
        self.assertEqual(len(self.called("model/list")), 2)

    def test_a_default_model_the_list_does_not_have_is_refused(self):
        self.fake.config = {"model": "my-own-model", "model_reasoning_effort": "high"}
        self.assertIn("my-own-model", self.refused())


class StartTest(Case):
    """U-start (G1): the calls, their order and what they carry."""

    def setUp(self):
        super().setUp()
        self.fake.projects = {str(self.lane): "trusted"}

    def test_calls_in_order_with_model_and_effort_on_thread_and_turn(self):
        prompt = "Lies BRIEF.md.\nDann: prüfe §3 — «alles».\n".encode()
        rc, out, err = self.start("--model", LUNA, "--effort", "low", "--name", "lane-one", stdin=prompt)
        self.assertEqual(rc, 0, err)
        self.assertEqual(self.fake.methods(), ["initialize", "initialized", "config/read", "model/list", "thread/start", "config/read", "thread/name/set", "turn/start"])
        tid = out["session"]
        self.assertEqual(self.called("thread/start"), [{"cwd": str(self.lane), "model": LUNA, "config": {"model_reasoning_effort": "low"}}])
        self.assertEqual(self.called("thread/name/set"), [{"threadId": tid, "name": "lane-one"}])
        self.assertEqual(self.called("turn/start"), [{"threadId": tid, "model": LUNA, "effort": "low", "input": [{"type": "text", "text": prompt.decode()}]}])
        self.assertEqual(out, {"session": tid, "model": LUNA, "effort": "low", "turn": self.fake.threads[tid]["turns"][-1][0], "server": "0.169.0"})

    def test_no_name_no_name_call(self):
        rc, _, err = self.start()
        self.assertEqual(rc, 0, err)
        self.assertNotIn("thread/name/set", self.fake.methods())

    def test_an_empty_or_undecodable_prompt_is_a_usage_error(self):
        for prompt in (b"", b"  \n", b"\xff\xfe"):
            rc, out, _ = self.start(stdin=prompt)
            self.assertEqual((rc, out), (2, None))
        self.assertNotIn("thread/start", self.fake.methods())

    def test_an_echo_that_differs_stops_before_the_turn(self):
        self.fake.echo = {"reasoningEffort": "high"}
        rc, out, err = self.start("--model", LUNA, "--effort", "low")
        self.assertEqual((rc, out), (1, None))
        self.assertIn("high", err)
        self.assertNotIn("turn/start", self.fake.methods())


class TrustTest(Case):
    """U-trust (G3): a start needs a trust decision Codex already holds, or --trust."""

    def verdict(self, cwd=None, *args):
        self.fake.log.clear()
        rc, out, err = self.run_helper("start", "--cwd", cwd or self.lane, *args, stdin=b"go")
        return rc, "thread/start" in self.fake.methods(), err

    def test_no_decision_is_refused_and_trust_goes_on(self):
        rc, started, err = self.verdict()
        self.assertEqual((rc, started), (1, False))
        self.assertIn("--trust", err)
        self.assertIn(str(self.lane), err)
        self.assertEqual(self.verdict(None, "--trust")[:2], (0, True))

    def test_a_decision_for_the_folder_either_way_is_a_decision(self):
        for level in ("trusted", "untrusted"):
            self.fake.projects = {str(self.lane): level}
            self.assertEqual(self.verdict()[:2], (0, True), level)

    def test_a_decision_for_the_repository_root_covers_a_subfolder_and_a_worktree(self):
        repo = self.root / "repo"
        (repo / "sub").mkdir(parents=True)
        self.git("init", "-q", cwd=repo)
        self.git("commit", "-q", "--allow-empty", "-m", "x", cwd=repo)
        tree = self.root / "tree"
        self.git("worktree", "add", "-q", str(tree), "-b", "side", cwd=repo)
        for folder in (repo / "sub", tree):
            self.fake.projects = {}
            self.assertEqual(self.verdict(folder)[:2], (1, False), folder)
            self.fake.projects = {str(repo): "trusted"}
            self.assertEqual(self.verdict(folder)[:2], (0, True), folder)

    def test_a_decision_for_an_ancestor_that_is_no_repository_root_does_not_count(self):
        self.fake.projects = {str(self.root): "trusted"}
        self.assertEqual(self.verdict()[:2], (1, False))

    def test_a_symlinked_spelling_is_found_by_either_name(self):
        link = self.root / "link"
        link.symlink_to(self.lane)
        for key in (self.lane, link):
            self.fake.projects = {str(key): "trusted"}
            self.assertEqual(self.verdict(link)[:2], (0, True), key)

    def test_codex_saving_an_entry_anyway_fails_the_start_and_names_it(self):
        repo = self.root / "repo"
        repo.mkdir()
        self.fake.projects = {str(repo): "untrusted", str(self.lane): "untrusted"}
        self.fake.auto_trust = True

        def start_saves(cwd, key):
            self.fake.projects.pop(key, None)
            self.fake.projects.setdefault(str(cwd), "untrusted")
            real_start = self.fake._result

            def result(session, method, params):
                answer = real_start(session, method, params)
                if method == "thread/start":
                    self.fake.projects[key] = "trusted"
                return answer

            self.fake._result = result
            self.addCleanup(lambda: setattr(self.fake, "_result", real_start))

        self.fake.auto_trust = False
        start_saves(self.lane, str(self.root))
        rc, started, err = self.verdict()
        self.assertEqual((rc, started), (1, True))
        self.assertIn(str(self.root), err)
        self.assertNotIn("turn/start", self.fake.methods())
        self.assertEqual(self.verdict(None, "--trust")[0], 0)

    def test_an_entry_another_session_saved_elsewhere_is_not_ours(self):
        self.fake.projects = {str(self.lane): "trusted"}
        real = self.fake._result

        def result(session, method, params):
            answer = real(session, method, params)
            if method == "thread/start":
                self.fake.projects["/somewhere/else"] = "trusted"
            return answer

        self.fake._result = result
        self.assertEqual(self.verdict()[:2], (0, True))


class PartialTest(Case):
    """U-partial (G6): what a failure after a change leaves, and that the prompt goes out once."""

    def setUp(self):
        super().setUp()
        self.fake.projects = {str(self.lane): "trusted"}

    def test_each_step_failing_or_silent(self):
        for method, plan, words in (
            ("thread/start", "error", ["thread/start"]),
            ("thread/start", "silent", ["no answer", "may have created"]),
            ("thread/name/set", "error", ["thread/name/set", "leaves no file"]),
            ("turn/start", "error", ["turn/start", "leaves no file"]),
            ("turn/start", "silent", ["may be running", "codex resume "]),
        ):
            self.fake.log.clear()
            self.fake.fail = {method: [plan]}
            rc, out, err = self.start("--model", LUNA, "--name", "n", env={"FLAKELAB_CODEX_CALL_SECONDS": "1"})
            self.assertEqual((rc, out), (1, None), f"{method} {plan}")
            for word in words:
                self.assertIn(word, err, f"{method} {plan}")
            self.assertLessEqual(len(self.called("turn/start")), 1, "the prompt is never sent twice")


class StateTest(Case):
    """U-state (G4)."""

    def test_each_status_has_its_word(self):
        words = {"idle": "idle", "working": "working", "approval": "approval", "question": "question", "both": "approval", "unloaded": "unloaded", "error": "error"}
        ids = [self.fake.add_thread(f"0000000{i}-0000-7000-8000-000000000000", state=s, model=SOL, effort="xhigh", name=f"lane-{s}") for i, s in enumerate(words)]
        rc, out, err = self.run_helper("state", *ids, "99999999-0000-7000-8000-000000000000")
        self.assertEqual(rc, 0, err)
        self.assertEqual([o["state"] for o in out], [*words.values(), "missing"])
        self.assertEqual(out[0], {"session": ids[0], "state": "idle", "model": SOL, "effort": "xhigh", "name": "lane-idle"})
        self.assertEqual(out[-1]["model"], None)
        self.assertEqual(len(self.called("thread/read")), len(ids) + 1, "each id is asked once")

    def test_an_unknown_status_word_is_named(self):
        self.fake.add_thread(T1, state="strange")
        rc, out, err = self.run_helper("state", T1)
        self.assertEqual((rc, out), (1, None))
        self.assertIn("somethingNew", err)

    def test_the_deadline_returns_what_arrived(self):
        ids = [self.fake.add_thread(t) for t in (T1, T2, T3)]
        self.fake.stall_after = 2
        rc, out, err = self.run_helper("state", "--deadline", "1", *ids, timeout=20)
        self.assertEqual(rc, 0, err)
        self.assertEqual([o["state"] for o in out], ["idle", "idle", None])

    def test_the_deadline_covers_a_server_that_accepts_and_never_answers(self):
        self.fake.add_thread(T1)
        self.fake.fail = {"initialize": ["silent"]}
        began = time.monotonic()
        rc, out, err = self.run_helper("state", "--deadline", "1", T1, timeout=20)
        self.assertEqual((rc, out), (1, None))
        self.assertIn("initialize", err)
        self.assertLess(time.monotonic() - began, 4)

    def test_repeated_ids_are_asked_once(self):
        self.fake.add_thread(T1)
        rc, out, _ = self.run_helper("state", T1, T1)
        self.assertEqual((rc, len(out), len(self.called("thread/read"))), (0, 1, 1))


class CloseTest(Case):
    """U-stop (G5): what counts as finished, and what a forced stop does."""

    def check(self, tid=T1):
        return self.run_helper("close-check", tid)

    def test_idle_without_helpers_or_commands_is_finished(self):
        self.fake.add_thread(T1, cwd="/work/lane")
        rc, out, err = self.check()
        self.assertEqual(rc, 0, err)
        self.assertEqual(out, {"session": T1, "finished": True, "state": "idle", "reasons": [], "cwd": "/work/lane", "name": None})
        self.assertEqual(self.called("thread/read")[-1], {"threadId": T1, "includeTurns": False}, "the state is read once more at the end")

    def test_unloaded_asks_for_no_helpers_and_no_terminals(self):
        self.fake.add_thread(T1, state="unloaded")
        rc, out, _ = self.check()
        self.assertEqual((rc, out["finished"], out["state"]), (0, True, "unloaded"))
        self.assertNotIn("thread/backgroundTerminals/list", self.fake.methods())
        self.assertNotIn("thread/loaded/list", self.fake.methods())

    def test_reasons(self):
        for state, word in (("working", "working"), ("approval", "approval"), ("question", "answer"), ("error", "error")):
            self.fake.threads.clear()
            self.fake.add_thread(T1, state=state)
            _, out, _ = self.check()
            self.assertFalse(out["finished"], state)
            self.assertIn(word, " ".join(out["reasons"]), state)

    def test_a_working_helper_agent_and_a_command_are_reasons(self):
        self.fake.add_thread(T1)
        self.fake.add_thread(T2, state="working", parent=T1, name="Darwin")
        self.fake.add_thread(T3, parent=T2)
        self.fake.add_thread("55555555-5555-7555-8555-555555555555", state="working")  # someone else's
        self.fake.terminals = {T3: ["sleep 300", "npm run dev"]}
        self.fake.page_size = 1
        _, out, err = self.check()
        self.assertEqual(out["finished"], False, err)
        self.assertEqual(out["reasons"], ["helper agent Darwin is working", "runs: sleep 300", "runs: npm run dev"])

    def test_a_terminal_list_that_cannot_be_read_is_a_reason(self):
        self.fake.add_thread(T1)
        self.fake.unknown = {"thread/backgroundTerminals/list"}
        _, out, _ = self.check()
        self.assertFalse(out["finished"])
        self.assertIn("could not be read", out["reasons"][0])

    def test_stop_interrupts_the_session_and_its_helpers_and_cleans(self):
        self.fake.add_thread(T1, state="working", turn="turn-root")
        self.fake.add_thread(T2, state="working", parent=T1, turn="turn-helper")
        self.fake.add_thread(T3, parent=T1)
        self.fake.terminals = {T1: ["sleep 300"], T3: ["tail -f log"]}
        rc, out, err = self.run_helper("stop", T1)
        self.assertEqual(rc, 0, err)
        self.assertEqual(self.called("turn/interrupt"), [{"threadId": T1, "turnId": "turn-root"}, {"threadId": T2, "turnId": "turn-helper"}])
        self.assertEqual(sorted(p["threadId"] for p in self.called("thread/backgroundTerminals/clean")), [T1, T2, T3])
        self.assertEqual(out, {"session": T1, "interrupted": [T1, T2], "cleaned": [T1, T2, T3]})
        self.assertEqual(self.check()[1]["finished"], True)

    def test_a_turn_that_changes_between_read_and_interrupt_is_read_again(self):
        self.fake.add_thread(T1, state="working", turn="turn-old")
        self.fake.turn_changes = 2
        rc, out, err = self.run_helper("stop", T1)
        self.assertEqual((rc, out["interrupted"]), (0, [T1]), err)
        self.assertEqual(len(self.called("turn/interrupt")), 3)

    def test_work_that_does_not_stop_ends_at_the_deadline(self):
        for attr, word in (("stubborn", "working"), ("sticky", "sleep 300")):
            self.fake.threads.clear()
            self.fake.stubborn = self.fake.sticky = False
            setattr(self.fake, attr, True)
            self.fake.add_thread(T1, state="working")
            self.fake.terminals = {T1: ["sleep 300"]}
            rc, out, err = self.run_helper("stop", T1, env={"FLAKELAB_CODEX_STOP_SECONDS": "2"}, timeout=30)
            self.assertEqual((rc, out), (1, None), attr)
            self.assertIn(word, err)

    def test_error_state_is_not_interrupted_and_unloaded_is_left_alone(self):
        self.fake.add_thread(T1, state="error")
        self.fake.terminals = {T1: ["sleep 300"]}
        rc, out, err = self.run_helper("stop", T1)
        self.assertEqual((rc, out), (0, {"session": T1, "interrupted": [], "cleaned": [T1]}), err)
        self.fake.log.clear()
        self.fake.add_thread(T2, state="unloaded")
        rc, out, _ = self.run_helper("stop", T2)
        self.assertEqual((rc, out), (0, {"session": T2, "interrupted": [], "cleaned": []}))
        self.assertNotIn("thread/backgroundTerminals/clean", self.fake.methods())

    def test_archive(self):
        self.fake.add_thread(T1)
        rc, out, _ = self.run_helper("archive", T1)
        self.assertEqual((rc, out, self.fake.archived), (0, {"session": T1, "archived": True}, [T1]))
        self.fake.fail = {"thread/archive": ["error"]}
        self.assertEqual(self.run_helper("archive", T1)[0], 1)


if __name__ == "__main__":
    if os.environ.get("FLAKELAB_CODEX_LIVE") == "1":
        live = load("codex_threads_live", "test-codex-threads-live.py")
        sys.exit(live.main())
    unittest.main()
