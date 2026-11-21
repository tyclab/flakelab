"""Read one key on the foreground terminal and return the choice to the launcher."""

import codecs
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


def choose():
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
        print(f"Model [Enter: {label}] {options}: ", end="", file=sys.stderr, flush=True)
        # The buffered text stream can take the next turn along with the choice.
        reader = codecs.getreader(sys.stdin.encoding)(sys.stdin.buffer.raw, errors="replace")
        key = reader.read(1)
    finally:
        termios.tcsetattr(fd, termios.TCSANOW, saved)
        print(file=sys.stderr)
    return choices.get(key, "default")


def start_choice():
    request = subprocess.run(["tycswap", "start", "--next", "show"], stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL)
    if request.returncode == 0 and request.stdout in (b"none\n", b"none"):
        return choose()
    return "default"


if __name__ == "__main__":
    try:
        print(start_choice())
    except KeyboardInterrupt:
        print("cancel")
