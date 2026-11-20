"""Native Claude task inputs and turn completion for flakelab sessions."""

import json
import os
import shlex
import subprocess
import sys
from pathlib import Path


def last_turn(path):
    # A turn can end with unrelated bookkeeping. Read backwards without loading
    # a long conversation (or mistaking another session's last update for ours).
    with path.open("rb") as stream:
        offset = stream.seek(0, 2)
        partial = b""
        while offset:
            size = min(offset, 65536)
            offset -= size
            stream.seek(offset)
            lines = (stream.read(size) + partial).split(b"\n")
            partial = lines.pop(0) if offset else b""
            for line in reversed(lines):
                if not line.strip():
                    continue
                try:
                    event = json.loads(line)
                except ValueError:
                    return "unknown"
                if not isinstance(event, dict):
                    return "unknown"
                if event.get("type") == "assistant":
                    message = event.get("message")
                    reason = message.get("stop_reason") if isinstance(message, dict) else None
                    if event.get("isApiErrorMessage") or reason in (
                        "refusal", "max_tokens", "model_context_window_exceeded",
                    ):
                        return "error"
                    if reason in ("end_turn", "stop_sequence"):
                        return "idle"
                    return "working"
                if event.get("type") == "user" and not event.get("isMeta"):
                    return "working"
    return "starting"


# Pass provider inputs from this client only. Cloud credentials can have a
# provider-specific name even when Claude selects the backend with one flag.
PROVIDER_PREFIXES = (
    "ANTHROPIC_", "CLAUDE_CODE_USE_", "AWS_", "GOOGLE_", "GCLOUD_",
    "CLOUDSDK_", "AZURE_", "FOUNDRY_", "VERTEX_",
)
PROVIDER_KEYS = {
    "CLAUDE_CONFIG_DIR", "CLAUDE_SECURESTORAGE_CONFIG_DIR",
    "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR",
    "CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR",
}


def provider_key(key):
    return key in PROVIDER_KEYS or key.startswith(PROVIDER_PREFIXES)


IDENTITY_KEYS = PROVIDER_KEYS | {
    "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_CUSTOM_HEADERS",
    "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY",
}


def explicit_identity(keys):
    return any(
        k in IDENTITY_KEYS or (k.startswith("ANTHROPIC_") and k.endswith("_BASE_URL"))
        for k in keys
    )


def launch(keys, args):
    env = {k: v for k, v in os.environ.items() if not provider_key(k) or k in keys}
    # An explicit profile or authentication mode belongs to the caller. The
    # managed PATH launcher handles ordinary starts; a custom identity runs
    # against the installer's native executable exactly as configured.
    program = str(Path.home() / ".local/bin/claude") if explicit_identity(keys) else "claude"
    os.execvpe(program, [program, *args], env)


def resume(environ, cwd, sid):
    # Only directory selectors can appear in a copyable command. A caller's
    # external provider needs its original credentials in the resuming shell.
    if not environ.is_file():
        sys.exit("Cannot identify the credential context of the session")
    entries = os.fsdecode(environ.read_bytes()).split("\0")
    env = dict(entry.split("=", 1) for entry in entries if "=" in entry)
    if not env:
        sys.exit("Cannot identify the credential context of the session")
    if not cwd or not Path(cwd).is_dir():
        sys.exit("Cannot locate the session's working directory")
    command = ["cd " + shlex.quote(cwd)]
    if explicit_identity(env):
        dirs = ("CLAUDE_CONFIG_DIR", "CLAUDE_SECURESTORAGE_CONFIG_DIR")
        selectors = [f"{k}={env[k]}" for k in dirs if k in env]
        for key in sorted(k for k in env if provider_key(k) and k not in dirs):
            if not key.isidentifier() or not key.isascii():
                sys.exit("Unsupported provider environment name")
            command.append('test "${' + key + '+set}" = set')
        if len(command) > 1:
            print("Resume in the shell configured for the original provider.", file=sys.stderr)
        args = (["env", *selectors] if selectors else []) + [str(Path.home() / ".local/bin/claude")]
    else:
        args = ["claude"]
    command.append(shlex.join([*args, "--resume", sid]))
    print(" && ".join(command))


def new_window(keys, args):
    # tmux takes -e NAME=value on argv. Send that command on stdin instead so
    # other processes cannot see custom authentication values in ps. Octal
    # escapes are tmux's own quoted byte syntax, including quotes/newlines.
    def quoted(word):
        return '"' + "".join(f"\\{byte:03o}" for byte in os.fsencode(word)) + '"'

    env_args = [arg for key in keys for arg in ("-e", f"{key}={os.environ[key]}")]
    command = " ".join(quoted(arg) for arg in [args[0], *env_args, *args[1:]])
    proc = subprocess.run(
        ["tmux", "start-server", ";", "source-file", "-"],
        input=(command + "\n").encode(),
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
    if proc.returncode:
        sys.exit("tmux could not create the Claude window")
    sys.stdout.buffer.write(proc.stdout)


if __name__ == "__main__":
    if sys.argv[1] == "turn":
        print(last_turn(Path(sys.argv[2])))
    elif sys.argv[1] == "resume":
        resume(Path(sys.argv[2]), *sys.argv[3:])
    elif sys.argv[1] == "keys":
        for key in sorted(os.environ):
            if provider_key(key):
                print(key)
    else:
        boundary = sys.argv.index("--")
        keys, args = sys.argv[2:boundary], sys.argv[boundary + 1 :]
        if sys.argv[1] == "window":
            new_window(keys, args)
        else:
            launch(keys, args)
