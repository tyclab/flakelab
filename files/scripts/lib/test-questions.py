"""Protocol, correlation, cancellation and credential handling without a live inbox."""

import io
import json
import tempfile
from pathlib import Path
import threading
import unittest
from unittest.mock import patch
import urllib.error

import questions


class FakeTransport:
    def __init__(self):
        self.calls = []
        self.created = threading.Event()
        self.answer = threading.Event()

    def post(self, body):
        self.calls.append(body)
        self.created.set()
        if body["op"] in {"create", "poll"}:
            return {"status": "answered", "answer": "Use the blue one"} if self.answer.is_set() else {"status": "pending"}
        return {"status": "cancelled" if body["op"] == "cancel" else "delivered"}


class QuestionTests(unittest.TestCase):
    def setUp(self):
        self.output = io.StringIO()
        self.transport = FakeTransport()
        self.server = questions.Server("claude", self.output, lambda: self.transport, interval=0.001)

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

if __name__ == "__main__":
    unittest.main(verbosity=2)
