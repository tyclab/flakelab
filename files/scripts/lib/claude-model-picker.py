"""Read one key on the foreground terminal and return the choice to the launcher."""

from array import array
import codecs
import fcntl
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import termios
import tty


def model_name(value):
    return value.strip() if isinstance(value, str) else ""


def configured_model():
    if model := model_name(os.getenv("ANTHROPIC_MODEL")):
        return model
    model = ""
    for path in (Path(".claude/settings.local.json"), Path(".claude/settings.json"),
                 Path.home() / ".claude/settings.json"):
        try:
            if not path.is_file():
                continue
            settings = json.loads(path.read_bytes())
        except (OSError, ValueError):
            continue
        if isinstance(settings, dict):
            env = settings.get("env")
            if isinstance(env, dict) and (override := model_name(env.get("ANTHROPIC_MODEL"))):
                return override
            model = model or model_name(settings.get("model"))
    return model


def discard_escape_tail(fd):
    # Snapshot the input queue so a lone Escape never waits for another key.
    queued = array("i", [0])
    fcntl.ioctl(fd, termios.FIONREAD, queued)
    remaining = queued[0]
    if not remaining:
        return
    prefix = os.read(fd, 1)
    if prefix not in (b"[", b"O"):
        return
    for offset in range(1, remaining):
        byte = os.read(fd, 1)
        if b"@" <= byte <= b"~":
            # X10 mouse reports carry three payload bytes after their final M.
            if prefix == b"[" and offset == 1 and byte == b"M":
                os.read(fd, min(3, remaining - offset - 1))
            return


def choose(terminal):
    model = configured_model()
    families = {"mythos", "fable", "opus", "sonnet", "haiku"}.intersection(
        re.findall(r"[a-z0-9]+", model.lower())
    )
    choices = {name[0]: name for name in ("mythos", "fable", "opus") if families != {name}}
    label = model or "Claude default"
    if not label.isprintable():
        label = ascii(label)
    options = " ".join(f"[{key}] {name.title()}" for key, name in choices.items())
    fd = sys.stdin.fileno()
    saved = termios.tcgetattr(fd)
    try:
        tty.setcbreak(fd, termios.TCSANOW)
        print(f"Model [Enter: {label}] {options}: ", end="", file=terminal, flush=True)
        # The buffered text stream can take the next turn along with the choice.
        reader = codecs.getreader(sys.stdin.encoding)(sys.stdin.buffer.raw, errors="replace")
        key = reader.read(1)
        if key == "\x1b":
            discard_escape_tail(fd)
    finally:
        termios.tcsetattr(fd, termios.TCSANOW, saved)
        print(file=terminal, flush=True)
    return choices.get(key, "default")


def start_choice():
    request = subprocess.run(["tycswap", "start", "--next", "show"], stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL)
    if request.returncode == 0 and request.stdout in (b"none\n", b"none"):
        with os.fdopen(3, "w") as terminal:
            return choose(terminal)
    return "default"


if __name__ == "__main__":
    try:
        print(start_choice())
    except KeyboardInterrupt:
        print("cancel")
