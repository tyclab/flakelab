"""The lane's Anthropic API key, read at use time from the first readable flakelab secrets file."""

from pathlib import Path
import shlex

# Never ANTHROPIC_API_KEY: zsh exports secrets.env into every shell, and that name moves Claude Code onto API billing.
KEY = "SESSION_ARCHIVE_ANTHROPIC_API_KEY"


class MissingSecret(RuntimeError):
    def __init__(self):
        super().__init__(f"{KEY} is not set in the flakelab secrets file")


def secret_files(env):
    home = Path(env.get("HOME") or Path.home())
    render = env.get("FLAKELAB_SECRETS_RENDER") or "/run/secrets/flakelab-env"
    return [name for name in (env.get("FLAKELAB_SECRETS_ENV", ""), render, str(home / ".config/flakelab/secrets.env"))
            if name]


def value_in(text):
    value = ""
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("export "):
            line = line[len("export "):]
        name, sep, raw = line.partition("=")
        if sep and name.strip() == KEY:
            try:
                parts = shlex.split(raw, comments=True)
            except ValueError:
                parts = []
            value = parts[0] if len(parts) == 1 else ""
    return value


def api_key(env) -> str:
    for name in secret_files(env):
        try:
            text = Path(name).read_text(errors="replace")
        except OSError:
            continue
        value = value_in(text)
        if not value:
            raise MissingSecret()
        return value
    raise MissingSecret()
