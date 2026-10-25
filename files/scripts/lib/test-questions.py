"""Protocol, correlation, cancellation and credential handling without a live inbox."""

import io
import json
import tempfile
from pathlib import Path
import threading
import time
import unittest
from unittest.mock import patch
import urllib.error

import questions


def lines(output):
    return [json.loads(line) for line in output.getvalue().splitlines()]


def dialog_requests(output):
    return [m for m in lines(output) if m.get("method") == "elicitation/create"]


def cancellations(output):
    return [m for m in lines(output) if m.get("method") == "notifications/cancelled"]


class FakeTransport:
    def __init__(self, output=None):
        self.calls = []
        self.created = threading.Event()
        self.answer = threading.Event()
        self.output, self.dialog_before_create = output, None
        self.answer_reply = {"status": "delivered"}
        self.fail_answer = None  # None | "protocol" | "network"
        self.fail_delivered = False
        self.down = False

    def post(self, body):
        self.calls.append(body)
        if self.down:
            raise ConnectionError("down")
        if body["op"] == "create" and self.dialog_before_create is None:
            self.dialog_before_create = bool(self.output and dialog_requests(self.output))
        self.created.set()
        if body["op"] == "answer":
            if self.fail_answer == "protocol":
                raise questions.ProtocolError("rejected")
            if self.fail_answer == "network":
                raise ConnectionError("down")
            return self.answer_reply
        if body["op"] in {"create", "poll"}:
            return {"status": "answered", "answer": "Use the blue one"} if self.answer.is_set() else {"status": "pending"}
        if body["op"] == "delivered" and self.fail_delivered:
            raise ConnectionError("down")
        return {"status": "cancelled" if body["op"] == "cancel" else "delivered"}


class BreakableOutput(io.StringIO):
    """stdout after the client died: every write raises."""

    broken = False

    def write(self, text):
        if self.broken:
            raise BrokenPipeError("client gone")
        return super().write(text)


class QuestionTests(unittest.TestCase):
    def setUp(self):
        self.output = io.StringIO()
        self.transport = FakeTransport(self.output)
        self.server = questions.Server("claude", self.output, lambda: self.transport, interval=0.001)

    def init(self, elicitation=True):
        capabilities = {"elicitation": {"form": {}, "url": {}}} if elicitation else {}
        self.server.handle({"id": 0, "method": "initialize",
                            "params": {"protocolVersion": "2025-06-18", "capabilities": capabilities}})
        self.output.seek(0)
        self.output.truncate()

    def reply(self, dialog_id, result):
        self.server.handle({"jsonrpc": "2.0", "id": dialog_id, "result": result})

    def start_without_create(self, ident=1):
        self.server.handle({"id": ident, "method": "tools/call", "params": {
            "name": "ask_question", "arguments": {"question": "Which colour?", "options": ["Red", "Blue"]}}})
        for _ in range(100):
            if dialog_requests(self.output):
                break
            time.sleep(0.01)
        with self.server.lock:
            return self.server.active[ident][1]

    def accept(self, content):
        [request] = dialog_requests(self.output)[-1:]
        self.reply(request["id"], {"action": "accept", "content": content})

    def result(self):
        [line] = [m for m in lines(self.output) if "result" in m and "method" not in m]
        return json.loads(line["result"]["content"][0]["text"])

    def start(self, ident=1):
        self.server.handle({"id": ident, "method": "tools/call", "params": {
            "name": "ask_question", "arguments": {"question": "Which colour?", "options": ["Red", "Blue"]}}})
        self.assertTrue(self.transport.created.wait(1))
        with self.server.lock:
            return self.server.active[ident][1]

    def test_both_clients_receive_answer_on_original_request(self):
        for agent in ("claude", "codex"):
            with self.subTest(agent=agent):
                output, transport = io.StringIO(), FakeTransport()
                transport.answer.set()
                server = questions.Server(agent, output, lambda: transport)
                server.ask(42, {"question": "Choose", "context": "Full detail " * 1000}, threading.Event())
                message = json.loads(output.getvalue())
                self.assertEqual(message["id"], 42)
                self.assertEqual(json.loads(message["result"]["content"][0]["text"])["answer"], "Use the blue one")
                self.assertEqual(transport.calls[0]["agent"], agent)
                self.assertEqual(transport.calls[-1]["op"], "delivered")

    def test_cancellation_clears_inbox_without_returning_an_answer(self):
        thread = self.start()
        self.server.handle({"method": "notifications/cancelled", "params": {"requestId": 1}})
        thread.join(1)
        self.assertFalse(thread.is_alive())
        self.assertEqual(self.transport.calls[-1]["op"], "cancel")
        self.assertEqual(self.output.getvalue(), "")

    def test_other_request_remains_live_after_one_is_cancelled(self):
        first, second = self.start(1), self.start(2)
        self.server.handle({"method": "notifications/cancelled", "params": {"requestId": 1}})
        first.join(1)
        self.transport.answer.set()
        second.join(1)
        self.assertEqual(json.loads(self.output.getvalue())["id"], 2)
        creates = [call for call in self.transport.calls if call["op"] == "create"]
        self.assertNotEqual(creates[0]["id"], creates[1]["id"])
        self.assertNotEqual(creates[0]["token"], creates[1]["token"])

    def test_timeout_is_an_error_not_an_answer(self):
        self.server.timeout = 0.01
        self.server.ask(9, {"question": "Choose"}, threading.Event())
        self.assertTrue(json.loads(self.output.getvalue())["result"]["isError"])
        self.assertEqual(self.transport.calls[-1]["op"], "cancel")

    def test_eof_cancels_pending_calls(self):
        thread = self.start()
        self.server.run(io.StringIO())
        self.assertFalse(thread.is_alive())
        self.assertEqual(self.transport.calls[-1]["op"], "cancel")

    def test_invalid_arguments_do_not_post(self):
        self.server.ask(1, {"question": "", "options": [3]}, threading.Event())
        self.assertEqual(self.transport.calls, [])
        self.assertTrue(json.loads(self.output.getvalue())["result"]["isError"])

    def test_discovery_negotiates_supported_protocol(self):
        self.server.handle({"id": 1, "method": "initialize", "params": {"protocolVersion": "2026-07-28"}})
        self.server.handle({"id": 2, "method": "tools/list"})
        first, second = map(json.loads, self.output.getvalue().splitlines())
        self.assertEqual(first["result"]["protocolVersion"], "2025-06-18")
        self.assertEqual(second["result"]["tools"][0]["name"], "ask_question")

    def test_secret_file_is_read_without_executing_shell(self):
        with tempfile.TemporaryDirectory() as temp:
            secret = Path(temp) / "secret.env"
            marker = Path(temp) / "should-not-exist"
            secret.write_text(f"UNRELATED=$(touch {marker})\nexport NOTIFY_WEBHOOK_URL='https://ha.invalid/api/webhook/test-secret'\n")
            with patch.dict("os.environ", {"FLAKELAB_SECRETS_ENV": str(secret), "NOTIFY_WEBHOOK_URL": ""}):
                self.assertEqual(questions.endpoint(), "https://ha.invalid/api/webhook/test-secret-questions")
            self.assertFalse(marker.exists())

    def test_http_errors_never_reveal_secret_url(self):
        with patch.dict("os.environ", {"NOTIFY_WEBHOOK_URL": "https://ha.invalid/api/webhook/test-secret"}):
            transport = questions.Transport()
        with patch.object(transport.opener, "open", side_effect=OSError(transport.url)):
            with self.assertRaises(ConnectionError) as raised:
                transport.post({})
        self.assertNotIn("test-secret", str(raised.exception))


    def test_http_400_is_a_protocol_error_without_the_secret(self):
        with patch.dict("os.environ", {"NOTIFY_WEBHOOK_URL": "https://ha.invalid/api/webhook/test-secret"}):
            transport = questions.Transport()
        for code, expected in ((400, questions.ProtocolError), (503, ConnectionError)):
            error = urllib.error.HTTPError(transport.url, code, "boom", {}, None)
            with patch.object(transport.opener, "open", side_effect=error):
                with self.assertRaises(expected) as raised:
                    transport.post({})
            self.assertNotIn("test-secret", str(raised.exception))

    def test_dialog_is_requested_before_the_inbox_when_the_client_can_show_it(self):
        self.init()
        self.start()
        [request] = dialog_requests(self.output)
        self.assertTrue(request["id"].startswith("q-"))
        self.assertEqual(request["params"]["message"], "Which colour?")
        schema = request["params"]["requestedSchema"]
        self.assertEqual(schema["properties"]["choice"]["enum"], ["Red", "Blue"])
        self.assertEqual(schema["properties"]["choice"]["enumNames"], ["Red", "Blue"])
        self.assertEqual(schema["properties"]["answer"]["maxLength"], 12000)
        self.assertNotIn("required", schema)
        self.assertTrue(self.transport.dialog_before_create)

    def test_free_text_question_requires_the_answer_field(self):
        self.init()
        self.server.handle({"id": 1, "method": "tools/call", "params": {"name": "ask_question",
                            "arguments": {"question": "Why?", "context": "Because."}}})
        self.assertTrue(self.transport.created.wait(1))
        [request] = dialog_requests(self.output)
        self.assertEqual(request["params"]["message"], "Why?\n\nBecause.")
        self.assertEqual(request["params"]["requestedSchema"]["required"], ["answer"])
        self.assertNotIn("choice", request["params"]["requestedSchema"]["properties"])

    def test_no_dialog_without_the_capability(self):
        self.init(elicitation=False)
        self.start()
        self.transport.answer.set()
        self.server.active[1][1].join(1)
        self.assertEqual(dialog_requests(self.output), [])
        self.assertEqual([m for m in lines(self.output) if "method" in m], [])

    def test_unknown_response_ids_are_ignored(self):
        self.server.handle({"jsonrpc": "2.0", "id": "q-99", "result": {"action": "accept"}})
        self.assertEqual(self.output.getvalue(), "")

    def test_terminal_answer_is_recorded_and_returned(self):
        self.init(); thread = self.start()
        self.accept({"choice": "Blue"}); thread.join(1)
        self.assertEqual(self.result() | {"question_id": None}, {"status": "answered", "answer": "Blue",
                                                                 "source": "terminal", "question_id": None})
        ops = [c["op"] for c in self.transport.calls]
        self.assertEqual(ops[0], "create"); self.assertEqual(ops[-1], "answer")
        self.assertNotIn("delivered", ops)
        self.assertEqual(self.transport.calls[-1]["answer"], "Blue")

    def test_terminal_answer_prefers_text_then_choice(self):
        for content, expected in (({"choice": "Red", "answer": " Purple "}, "Purple"),
                                  ({"choice": "Red", "answer": "  "}, "Red")):
            with self.subTest(content=content):
                self.setUp(); self.init(); thread = self.start()
                self.accept(content); thread.join(1)
                self.assertEqual(self.result()["answer"], expected)

    def test_empty_accept_reopens_the_dialog(self):
        self.init(); thread = self.start()
        self.accept({})
        for _ in range(100):
            if len(dialog_requests(self.output)) == 2:
                break
            time.sleep(0.01)
        self.assertEqual(len(dialog_requests(self.output)), 2)
        self.accept({"choice": "Red"}); thread.join(1)
        self.assertEqual(self.result()["answer"], "Red")

    def test_inbox_wins_a_tie(self):
        self.init(); thread = self.start()
        self.transport.answer_reply = {"status": "answered", "answer": "Red"}
        self.accept({"answer": "Blue"}); thread.join(1)
        result = self.result()
        self.assertEqual((result["answer"], result["source"], result["discarded_terminal_answer"]),
                         ("Red", "inbox", "Blue"))
        self.assertEqual(self.transport.calls[-1]["op"], "delivered")

    def test_cancelled_inbox_turns_a_terminal_answer_into_an_error(self):
        self.init(); thread = self.start()
        self.transport.answer_reply = {"status": "cancelled"}
        self.accept({"answer": "Blue"}); thread.join(1)
        self.assertTrue(lines(self.output)[-1]["result"]["isError"])

    def test_inbox_answer_carries_its_source(self):
        self.init(elicitation=False); thread = self.start()
        self.transport.answer.set(); thread.join(1)
        self.assertEqual(self.result()["source"], "inbox")

    def test_inbox_answer_cancels_the_dialog_once(self):
        self.init(); thread = self.start()
        self.transport.answer.set(); thread.join(1)
        [cancelled] = cancellations(self.output)
        self.assertEqual(cancelled["params"]["requestId"], dialog_requests(self.output)[0]["id"])
        self.accept({"choice": "Red"})
        self.assertEqual(len([m for m in lines(self.output) if "result" in m and "method" not in m]), 1)
        self.assertEqual(self.result()["source"], "inbox")

    def test_decline_keeps_waiting_for_the_inbox(self):
        self.init(); thread = self.start()
        [request] = dialog_requests(self.output)
        self.reply(request["id"], {"action": "decline"})
        time.sleep(0.02)
        self.assertEqual([c["op"] for c in self.transport.calls if c["op"] not in {"create", "poll"}], [])
        self.transport.answer.set(); thread.join(1)
        self.assertEqual(cancellations(self.output), [])
        self.assertEqual(self.result()["source"], "inbox")

    def test_elicitation_error_is_a_decline(self):
        self.init(); thread = self.start()
        [request] = dialog_requests(self.output)
        self.server.handle({"jsonrpc": "2.0", "id": request["id"], "error": {"code": -32601, "message": "no"}})
        self.transport.answer.set(); thread.join(1)
        self.assertEqual(self.result()["source"], "inbox")

    def test_call_cancellation_closes_dialog(self):
        self.init(); thread = self.start()
        self.server.handle({"method": "notifications/cancelled", "params": {"requestId": 1}})
        thread.join(1)
        self.assertEqual(len(cancellations(self.output)), 1)
        self.assertEqual(self.transport.calls[-1]["op"], "cancel")
        self.assertEqual([m for m in lines(self.output) if "result" in m and "method" not in m], [])

    def test_eof_and_expiry_close_dialogs(self):
        self.init(); thread = self.start()
        self.server.run(io.StringIO()); thread.join(1)
        self.assertEqual(len(cancellations(self.output)), 1)
        self.setUp(); self.init(); self.server.timeout = 0.01
        self.server.ask(9, {"question": "Choose"}, threading.Event())
        self.assertEqual(len(cancellations(self.output)), 1)
        self.assertTrue(lines(self.output)[-1]["result"]["isError"])

    def test_dialog_outlives_an_unreachable_inbox(self):
        self.init(); self.transport.down = True
        thread = self.start_without_create()
        self.accept({"answer": "Blue"}); thread.join(2)
        result = self.result()
        self.assertEqual((result["answer"], result["source"], result["inbox"]), ("Blue", "terminal", "unavailable"))

    def test_declined_dialog_with_unreachable_inbox_is_the_usual_error(self):
        self.init(); self.transport.down = True
        thread = self.start_without_create()
        [request] = dialog_requests(self.output)
        self.reply(request["id"], {"action": "decline"}); thread.join(2)
        self.assertTrue(lines(self.output)[-1]["result"]["isError"])

    def test_rejected_answer_op_falls_back_to_cancel(self):
        self.init(); thread = self.start()
        self.transport.fail_answer = "protocol"
        self.accept({"answer": "Blue"}); thread.join(1)
        self.assertEqual(self.result()["inbox"], "unsupported")
        self.assertEqual(self.transport.calls[-1]["op"], "cancel")

    def test_answer_op_network_failure_retries_then_reports_unavailable(self):
        self.init(); self.server.answer_retry = 0.02; thread = self.start()
        self.transport.fail_answer = "network"
        self.accept({"answer": "Blue"}); thread.join(2)
        self.assertEqual(self.result()["inbox"], "unavailable")
        self.assertGreater(len([c for c in self.transport.calls if c["op"] == "answer"]), 1)
        self.assertNotIn("cancel", [c["op"] for c in self.transport.calls])

    def test_dialogs_are_serialised(self):
        self.init(); first, second = self.start(1), self.start(2)
        time.sleep(0.02)
        self.assertEqual(len(dialog_requests(self.output)), 1)
        self.transport.answer.set()            # inbox answers both
        first.join(1); second.join(1)
        self.assertLessEqual(len(dialog_requests(self.output)), 2)
        results = [m for m in lines(self.output) if "result" in m and "method" not in m]
        self.assertEqual(sorted(m["id"] for m in results), [1, 2])

    def test_queued_dialog_opens_when_the_first_resolves(self):
        self.init(); first, second = self.start(1), self.start(2)
        self.accept({"choice": "Red"}); first.join(1)
        for _ in range(100):
            if len(dialog_requests(self.output)) == 2:
                break
            time.sleep(0.01)
        self.assertEqual(len(dialog_requests(self.output)), 2)
        self.accept({"choice": "Blue"}); second.join(1)
        answers = sorted(json.loads(m["result"]["content"][0]["text"])["answer"]
                         for m in lines(self.output) if "result" in m and "method" not in m)
        self.assertEqual(answers, ["Blue", "Red"])

    def test_tie_win_survives_a_failed_delivered_post(self):
        self.init(); thread = self.start()
        self.transport.answer_reply = {"status": "answered", "answer": "Red"}
        self.transport.fail_delivered = True
        self.accept({"answer": "Blue"}); thread.join(1)
        self.assertEqual((self.result()["answer"], self.result()["source"]), ("Red", "inbox"))
        ops = [c["op"] for c in self.transport.calls]
        self.assertEqual(ops[-1], "delivered")
        self.assertNotIn("cancel", ops)

    def test_broken_output_still_cancels_the_inbox_and_frees_the_dialog_lock(self):
        self.output = BreakableOutput()
        self.transport = FakeTransport(self.output)
        self.server = questions.Server("claude", self.output, lambda: self.transport, interval=0.001)
        self.init(); thread = self.start()
        self.output.broken = True
        self.server.run(io.StringIO()); thread.join(1)
        self.assertFalse(thread.is_alive())
        self.assertEqual(self.transport.calls[-1]["op"], "cancel")
        self.assertTrue(self.server.dialog_lock.acquire(blocking=False))
        self.assertEqual(self.server.active, {})

    def test_malformed_dialog_reply_is_a_decline(self):
        self.init(); thread = self.start()
        [request] = dialog_requests(self.output)
        self.reply(request["id"], "accept")
        self.transport.answer.set(); thread.join(1)
        self.assertFalse(thread.is_alive())
        self.assertEqual(self.result()["source"], "inbox")

if __name__ == "__main__":
    unittest.main(verbosity=2)
