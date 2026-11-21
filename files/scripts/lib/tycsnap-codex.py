"""Observe Codex's native thread title in a registered Windows Terminal pane.

Only stdout goes through a tty pair. Native Codex keeps the shell's process
group, controlling tty, stdin and stderr, including raw mode and job control.
"""

import errno
import fcntl
import hashlib
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import sys
import termios
import threading

import codex_threads
import tycsnap

TITLE = 'tui.terminal_title=["thread-id"]'
# 0.171.0 shortens its 36-character session ID to 29 characters and "...".
TITLE_ID = re.compile(rb"([0-9a-f]{8}(?:-[0-9a-f]{4}){3}-(?:[0-9a-f]{5}(?=\.\.\.)|[0-9a-f]{12}))(?:\.\.\.)?\Z", re.I)
NON_TUI = set("exec e review login logout mcp plugin app-server remote-control completion update doctor sandbox debug "
              "apply a queue archive delete migrate-rollouts migrate-nfs-db unarchive cloud exec-server features help".split())
VALUE_OPTIONS = {"-m", "--model", "-C", "--cd", "-i", "--image", "-s", "--sandbox", "--add-dir"}
SWITCHES = {"--worktree", "--no-alt-screen", "--last", "--all", "--approve-for-me",
            "--dangerously-bypass-approvals-and-sandbox"}


def local_launch(args):
    """Only select the shared local transport for ordinary native TUI invocations.

    Subcommands, custom configuration/profiles/executors, nonlocal servers and
    new or unfamiliar switches retain their native startup path and arguments.
    """
    if any(key in os.environ for key in ("CODEX_EXEC_SERVER_URL", "OPENAI_FEDERATION_RULE_ID", "OPENAI_IDENTITY_TOKEN_FILE",
                                        "OPENAI_IDENTITY_TOKEN_SOURCE", "OPENAI_SPIFFE_AUDIENCE", "OPENAI_SPIFFE_ID")):
        return False
    it = iter(args)
    positional = False
    native_only = False
    transport = "implicit"
    for arg in it:
        if arg == "--":
            break
        option, eq, value = arg.partition("=")
        if option in ("--add-dir", "--worktree"):
            native_only = True
        if option in VALUE_OPTIONS:
            if not eq and next(it, None) is None:
                return False
        elif option == "--remote":
            target = value if eq else next(it, "")
            if target != "unix://":
                if not target.startswith("unix://"):
                    return False
                try:
                    if not Path(target[7:]).samefile(control_socket()):
                        return False
                except OSError:
                    return False
            transport = "explicit"
        elif arg.startswith("-") and arg not in SWITCHES:
            return False
        elif not arg.startswith("-") and not positional:
            if arg in NON_TUI:
                return False
            positional = True
    if native_only:
        return "observe" if transport == "implicit" else False
    return transport


def control_socket():
    home = Path(os.environ.get("CODEX_HOME") or Path.home() / ".codex")
    return home / "app-server-control/app-server-control.sock"


class Titles:
    """Recognize only complete OSC 0/2 titles; discard all other bytes immediately."""

    def __init__(self):
        self.state = "text"
        self.body = bytearray()
        self.escaped = False

    def consume(self, data):
        results = []
        for byte in data:
            if self.state == "text":
                if byte == 27:
                    self.state = "escape"
            elif self.state == "escape":
                if byte == ord("]"):
                    self.state = "osc"
                elif byte in b"PX^_":  # DCS, SOS, PM, APC can themselves contain OSC-like text.
                    self.state = "control"
                elif byte != 27:
                    self.state = "text"
            elif self.state == "osc" and byte in b"02":
                self.state = "semicolon"
            elif self.state == "semicolon" and byte == ord(";"):
                self.state = "title"
            elif (self.escaped and byte == 92) or (byte == 7 and self.state != "control"):
                if self.state in ("title", "invalid"):
                    match = TITLE_ID.fullmatch(self.body)
                    results.append(match[1].decode().lower() if match else "")
                self.body.clear()
                self.escaped = False
                self.state = "text"
            elif byte == 27:
                self.escaped = True
            else:
                if self.state == "title":
                    if not self.escaped and len(self.body) < 36 and byte in b"0123456789abcdefABCDEF-.":
                        self.body.append(byte)
                    else:
                        self.body.clear()
                        self.state = "invalid"
                elif self.state in ("osc", "semicolon"):
                    self.state = "other"
                self.escaped = False
        return results


def launch_directory(args):
    cwd = os.getcwd()
    options = iter(args)
    for arg in options:
        if arg == "--":
            break
        flag, equal, value = arg.partition("=")
        if flag in VALUE_OPTIONS | {"--remote"}:
            value = value if equal else next(options, "")
            if flag in ("-C", "--cd"):
                cwd = os.path.abspath(value)
    return cwd


def daemon_autostarts(cwd):
    # Use the native config loader, respecting per-directory config and sign-in modes.
    try:
        result = subprocess.run(["codex", "features", "list"], cwd=cwd, stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=3)
        features = {cols[0] for row in result.stdout.splitlines() if (cols := row.split()) and cols[-1] == b"true"}
        return (result.returncode == 0 and b"daemon_auto_start" in features
                and not features.intersection({b"gateway_setup_wizard", b"gcp_setup_wizard"}))
    except (OSError, subprocess.TimeoutExpired):
        return False


def local_socket(alias, directory=None):
    # Codex 0.171's verified_local_daemon_socket: a socket bound directly at
    # CODEX_HOME's advertised path could be an SSH forward to another machine.
    directory = directory or Path("/tmp").resolve() / f"codex-daemon-{os.geteuid()}"
    try:
        private = directory.lstat()
        digest = hashlib.sha256(os.fsencode(alias.parent.resolve() / alias.name)).hexdigest()
        endpoint = directory / digest
        if (stat.S_ISDIR(private.st_mode) and private.st_uid == os.geteuid()
                and stat.S_IMODE(private.st_mode) == 0o700 and alias.readlink() == endpoint and endpoint.is_socket()):
            return endpoint
    except OSError:
        pass
    return None


def daemon_ready():
    endpoint = local_socket(control_socket())
    if not endpoint:
        return False
    try:
        codex_threads.Server(deadline=codex_threads.Deadline(1), socket_path=endpoint).close()
        return True
    except (OSError, ValueError, codex_threads.Refusal):
        return False


def loaded(prefix):
    endpoint = local_socket(control_socket())
    if not endpoint:
        return ""
    server = codex_threads.Server(deadline=codex_threads.Deadline(2), socket_path=endpoint)
    try:
        ids = {sid for sid in codex_threads.loaded_ids(server) if tycsnap.uuid(sid) == sid and sid.startswith(prefix)}
        return ids.pop() if len(ids) == 1 else ""
    finally:
        server.close()


class CurrentTitle:
    """One outstanding title, never terminal output; a slow server cannot block the TUI."""

    def __init__(self, record):
        self.record = record
        self.changed = threading.Condition()
        self.generation = 0
        self.prefix = None
        threading.Thread(target=self.resolve, daemon=True).start()

    def update(self, prefix):
        with self.changed:
            if prefix != self.prefix:
                # Never show the new title while the previous thread is still recoverable.
                self.record("")
                self.prefix = prefix
                self.generation += 1
                self.changed.notify()

    def refresh(self, *_):
        # zsh may have cleared the snapshot at the prompt while this job was stopped.
        with self.changed:
            self.generation += 1
            self.changed.notify()

    def resolve(self):
        previous = 0
        while True:
            with self.changed:
                self.changed.wait_for(lambda: previous != self.generation)
                previous, prefix = self.generation, self.prefix
            while prefix:
                try:
                    sid = loaded(prefix)
                except (OSError, ValueError, codex_threads.Refusal):
                    sid = ""
                with self.changed:
                    if previous != self.generation:
                        break
                    if sid:
                        self.record(sid)
                        break
                    # A new title can precede publication in thread/loaded/list.
                    self.changed.wait_for(lambda: previous != self.generation, timeout=1)
                    if previous != self.generation:
                        break


def observe(master, outer, parent, start, snapshot, cwd, passive):
    # The original executable remains the foreground child that zsh waits on.
    # Its stdout's termios output processing is disabled on the new tty: the
    # real terminal performs its own output processing when receiving bytes.
    parser = Titles()

    def record(sid):
        try:
            tycsnap.locked_command(*snapshot, "codex-title", [str(parent), start, sid, cwd])
        except (OSError, ValueError, KeyError):
            pass  # The shell can close or another boot can take ownership.

    current = CurrentTitle(record)
    if passive:
        # Without an ID title, autosave can still identify a standalone rollout.
        current.prefix = ""
    else:
        current.update("")

    def resize(*_):
        try:
            size = fcntl.ioctl(outer, termios.TIOCGWINSZ, bytes(8))
            if size != fcntl.ioctl(master, termios.TIOCGWINSZ, bytes(8)):
                fcntl.ioctl(master, termios.TIOCSWINSZ, size)
                os.kill(parent, signal.SIGWINCH)
        except OSError:
            pass

    signal.signal(signal.SIGWINCH, resize)
    signal.signal(signal.SIGCONT, current.refresh)
    resize()
    while True:
        try:
            data = os.read(master, 65536)
            if not data:
                return
            # Locate the first escape using bytes.find, avoiding a Python loop
            # over ordinary output on every redraw.
            offset = data.find(b"\x1b") if parser.state == "text" else 0
            if offset >= 0:
                for prefix in parser.consume(data[offset:]):
                    current.update(prefix)
            view = memoryview(data)
            while view:
                view = view[os.write(outer, view):]
        except OSError as exc:
            if exc.errno in (errno.EIO, errno.EBADF, errno.EPIPE):
                return
            raise


def shared_launch(args, cwd, transport):
    explicit = transport == "explicit"
    if not explicit and not daemon_autostarts(cwd):
        return None
    if not daemon_ready():
        if explicit or (control_socket().is_socket() and not local_socket(control_socket())):
            return None
        # Native Codex excludes WSL's Windows filesystems from managed daemon
        # startup. Let it decide the connection itself for homes on 9p/DrvFS.
        fs = subprocess.run(["stat", "-f", "-c", "%t", str(control_socket().parent.parent)],
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        if fs.returncode or fs.stdout.strip() == b"1021997":
            return None
        started = subprocess.run(["codex", "app-server", "daemon", "start"], stdin=subprocess.DEVNULL,
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if started.returncode or not daemon_ready():
            return None
    return ["codex", *([] if explicit else ["--remote", "unix://"]), "-c", TITLE, *args]


def main():
    snapshot = sys.argv[1:5]
    args = sys.argv[5:]
    native = ["codex", *args]
    parent = os.getpid()
    owner = os.environ.get("FLAKELAB_TYCSNAP_OWNER", "")
    stat = tycsnap.proc_stat(str(parent))
    if not (os.isatty(0) and os.isatty(1) and stat and owner.isdecimal() and tycsnap.descends_from(str(parent), owner)
            and os.tcgetpgrp(0) == os.getpgrp()):
        os.execvp("codex", native)
    transport = local_launch(args)
    if not transport:
        os.execvp("codex", native)
    cwd = launch_directory(args)
    passive = transport == "observe"
    if not passive:
        title_args = shared_launch(args, cwd, transport)
        if not title_args:
            os.execvp("codex", native)
        native = title_args
    master, slave = os.openpty()
    settings = termios.tcgetattr(slave)
    settings[1] = 0
    termios.tcsetattr(slave, termios.TCSANOW, settings)
    fcntl.ioctl(slave, termios.TIOCSWINSZ, fcntl.ioctl(1, termios.TIOCGWINSZ, bytes(8)))
    if not os.fork():
        os.close(slave)
        try:
            observe(master, 1, parent, stat[3], snapshot, cwd, passive)
        finally:
            os._exit(0)
    os.close(master)
    os.dup2(slave, 1)
    os.close(slave)
    os.execvp("codex", native)


if __name__ == "__main__":
    main()
