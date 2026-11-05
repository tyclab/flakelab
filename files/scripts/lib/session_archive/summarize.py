"""The model side: prompts with the operator's areas, the Messages API transport, a stub for tests, the per-window and
merge calls, list prices and the per-run budget. No request or response body and no key is logged or raised."""

from collections.abc import Callable
import copy
from dataclasses import dataclass
import http.client
import json
import os
from pathlib import Path
import re
import time
from typing import Protocol
import urllib.error
import urllib.request

from session_archive.config import RESERVED_AREA
from session_archive.secrets import KEY

PROMPTS = Path(__file__).resolve().parents[3] / "config/session-archive"
SYSTEM, SCHEMA, MERGE = "summarize_system.txt", "summarize_schema.json", "merge_system.txt"
UNCLEAR = f"{RESERVED_AREA}: none fits or the session spans two"
WINDOW_TAIL = "Summarize the transcript window above as the system prompt says."
MERGE_TAIL = "Merge the window summaries above into one, as the system prompt says."
URL = "https://api.anthropic.com/v1/messages"
MAX_TOKENS = 16_000
RETRY_HTTP = 429
ATTEMPTS = 4
USAGE = ("input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens")
# List prices in USD per million tokens (input, output); cache tokens are priced as input.
PRICES = {"claude-haiku-5-5": (0.10, 0.50), "claude-sonnet-5-5": (2.0, 10.0), "claude-opus-5-5": (4.0, 20.0)}
DATED = re.compile(r"-[0-9]{8}$")
UNPARSABLE = "unparsable output"
STUB_USAGE = {"input_tokens": 1000, "output_tokens": 100, "cache_creation_input_tokens": 0,
              "cache_read_input_tokens": 0}


class UnknownModel(ValueError):
    def __init__(self, model_id):
        super().__init__(f"no list price for model {model_id}")


class SummarizeError(RuntimeError):
    """A call that gave no usable summary; reason is model_error or unparsable, as the store records it."""

    def __init__(self, reason, detail):
        super().__init__(f"{reason}: {detail}")
        self.reason = reason


@dataclass(frozen=True)
class Completion:
    parsed: dict | None
    usage: dict
    usd: float
    model_id: str
    stop_reason: str | None
    error: str | None


class Transport(Protocol):
    def complete(self, system: str, user: str, schema: dict, model: str, effort: str,
                 max_tokens: int = MAX_TOKENS) -> Completion: ...


def rates(model_id) -> tuple[float, float]:
    found = PRICES.get(DATED.sub("", model_id))
    if found is None:
        raise UnknownModel(model_id)
    return found


def price(usage, model_id) -> float:
    per_input, per_output = rates(model_id)
    sent = sum(usage.get(name) or 0 for name in USAGE if name != "output_tokens")
    return (sent * per_input + (usage.get("output_tokens") or 0) * per_output) / 1e6


def completion(text, stop_reason, usage, model, model_id):
    """One finished response, priced at the requested model's rates; parsed only when it ended with a JSON object."""
    usage = {name: int(usage.get(name) or 0) for name in USAGE}
    usd = price(usage, model)
    if stop_reason != "end_turn":
        return Completion(None, usage, usd, model_id, stop_reason, f"stop_reason {stop_reason}")
    try:
        parsed = json.loads(text)
    except ValueError:
        parsed = None
    if not isinstance(parsed, dict):
        return Completion(None, usage, usd, model_id, stop_reason, UNPARSABLE)
    return Completion(parsed, usage, usd, model_id, stop_reason, None)


class ApiTransport:
    def __init__(self, key, timeout=600, sleep=time.sleep):
        if not re.fullmatch(r"[\x21-\x7e]+", key):
            raise ValueError(f"{KEY} is not a value an HTTP header can carry")
        self._key, self.timeout, self.sleep = key, timeout, sleep

    def complete(self, system, user, schema, model, effort, max_tokens=MAX_TOKENS) -> Completion:
        rates(model)  # a model without a list price would run outside the budget: refuse it before any call
        body = {"model": model, "max_tokens": max_tokens, "system": system, "thinking": {"type": "adaptive"},
                "output_config": {"effort": effort, "format": {"type": "json_schema", "schema": schema}},
                "messages": [{"role": "user", "content": user}]}
        data, failure = json.dumps(body).encode(), None
        for attempt in range(1, ATTEMPTS + 1):
            if attempt > 1:
                self.sleep(20 * (attempt - 1))
            request = urllib.request.Request(URL, data=data, method="POST", headers={
                "x-api-key": self._key, "anthropic-version": "2023-06-01", "content-type": "application/json"})
            try:
                with urllib.request.urlopen(request, timeout=self.timeout) as response:
                    raw = response.read()
            except urllib.error.HTTPError as error:
                error.close()
                failure = f"http {error.code}"
                if error.code == RETRY_HTTP or error.code >= 500:
                    continue
                break
            except (OSError, http.client.HTTPException) as error:
                failure = f"network {type(getattr(error, 'reason', error)).__name__}"
                continue
            return self.answer(raw, model)
        return Completion(None, dict.fromkeys(USAGE, 0), 0.0, model, None, failure)

    def answer(self, raw, model):
        try:
            message = json.loads(raw)
        except ValueError:
            message = None
        if not isinstance(message, dict):
            return Completion(None, dict.fromkeys(USAGE, 0), 0.0, model, None, "response is not a message")
        text = "".join(block.get("text", "") for block in message.get("content") or []
                       if isinstance(block, dict) and block.get("type") == "text")
        return completion(text, message.get("stop_reason"), message.get("usage") or {}, model,
                          message.get("model") or model)


class StubTransport:
    """A Transport for tests: plays responses in order (a Completion as is, a dict or str as the model's text) and
    records each call's arguments in calls."""

    def __init__(self, responses, usage=STUB_USAGE):
        self.responses, self.usage, self.calls = list(responses), usage, []

    def complete(self, system, user, schema, model, effort, max_tokens=MAX_TOKENS) -> Completion:
        self.calls.append({"system": system, "user": user, "schema": schema, "model": model, "effort": effort,
                           "max_tokens": max_tokens})
        if not self.responses:
            raise RuntimeError("StubTransport has no response left")
        response = self.responses.pop(0)
        if isinstance(response, Completion):
            return response
        text = response if isinstance(response, str) else json.dumps(response)
        return completion(text, "end_turn", self.usage, model, model)


def asset(name, env=os.environ) -> str:
    """A prompt asset; the wrapper names the store copy in SESSION_ARCHIVE_PROMPTS, a checkout reads its own."""
    return (Path(env.get("SESSION_ARCHIVE_PROMPTS") or PROMPTS) / name).read_text()


def system_prompt(base, areas) -> str:
    """base, which ends with its `## Areas` heading, then one `<name>: <description>` line per area in config order."""
    lines = [f"{name}: {' '.join(area.description.split())}" for name, area in areas.items()] + [UNCLEAR]
    return base.rstrip("\n") + "\n\n" + "\n".join(lines) + "\n"


def schema(base, areas) -> dict:
    shaped = copy.deepcopy(base)
    shaped["properties"]["area"]["enum"] = [*areas, RESERVED_AREA]
    return shaped


def conforms(value, shape) -> bool:
    """value against the JSON Schema subset the lane's schema uses: every property required, no others."""
    if "enum" in shape and value not in shape["enum"]:
        return False
    kind = shape.get("type")
    if kind == "object":
        properties = shape["properties"]
        return (isinstance(value, dict) and set(value) == set(properties)
                and all(conforms(value[name], part) for name, part in properties.items()))
    if kind == "array":
        return isinstance(value, list) and all(conforms(item, shape["items"]) for item in value)
    if kind == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    return kind == "string" and isinstance(value, str)


def checked(done: Completion, shape, charge: Callable[[Completion], None] | None) -> dict:
    """The summary of a completion that fits shape; charge sees every completion first, failed ones too."""
    if charge:
        charge(done)
    if done.error and done.error != UNPARSABLE:
        raise SummarizeError("model_error", done.error)
    if done.error or not conforms(done.parsed, shape):
        raise SummarizeError("unparsable", "the output does not fit the schema")
    return done.parsed


def window(transport, cfg, window, areas, *, charge=None) -> dict:
    shape = schema(json.loads(asset(SCHEMA)), areas)
    done = transport.complete(system_prompt(asset(SYSTEM), areas), f"{window.text}\n\n{WINDOW_TAIL}", shape, cfg.model,
                              cfg.effort)
    return checked(done, shape, charge)


def merge(transport, cfg, parts: list[dict], areas, *, charge=None) -> dict:
    """One summary from the windows' summaries, in window order; a single window's is already the session's."""
    if not parts:
        raise ValueError("no window summaries to merge")
    if len(parts) == 1:
        return parts[0]
    shape = schema(json.loads(asset(SCHEMA)), areas)
    user = "".join(f"PART {number} of {len(parts)}\n{json.dumps(part, ensure_ascii=False)}\n\n"
                   for number, part in enumerate(parts, 1)) + MERGE_TAIL
    done = transport.complete(system_prompt(asset(MERGE), areas), user, shape, cfg.model, cfg.effort)
    return checked(done, shape, charge)


class Budget:
    """One run's spend, summed from the store's ledger: allow() is False once it reaches cap_usd."""

    def __init__(self, store, run_id, cap_usd):
        self.store, self.run_id, self.cap_usd = store, run_id, cap_usd

    def allow(self) -> bool:
        return self.store.run_usd(self.run_id) < self.cap_usd

    def charge(self, uuid, model_id, usage, usd):
        self.store.ledger_add(self.run_id, uuid, model_id, usage, usd)
