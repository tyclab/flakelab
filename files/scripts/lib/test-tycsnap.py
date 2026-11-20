"""Offline TycSnap coverage through the installed sessions script's interface."""

import concurrent.futures
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
CMD = SCRIPTS / "claude-sessions"
A = "11111111-1111-1111-1111-111111111111"
B = "22222222-2222-2222-2222-222222222222"
C = "33333333-3333-3333-3333-333333333333"
SID = "dddddddd-dddd-dddd-dddd-dddddddddddd"
US = "\x1f"


class Tabs(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.base = Path(tmp.name)
        self.home = self.base / "home"
        self.home.mkdir()
        self.bin = self.base / "bin"
        self.bin.mkdir()
        self.proc = self.base / "proc"
        self.boot = self.base / "boot"
        self.boot.write_text("aaaaaaaaaaaa")
        self.env = dict(os.environ, HOME=str(self.home), XDG_STATE_HOME=str(self.base / "state"),
                        PATH=f"{self.bin}:{SCRIPTS}:{os.environ['PATH']}", WSL_DISTRO_NAME="test",
                        FLAKELAB_BOOT_ID_FILE=str(self.boot), FLAKELAB_MACHINE_ID_FILE=str(self.base / "missing"),
                        FLAKELAB_STATE_ROOT=str(self.base), FLAKELAB_PROC_ROOT=str(self.proc))
        for var in ("CLAUDECODE", "CODEX_THREAD_ID", "TMUX", "FLAKELAB_TYCSNAP_SOURCE"):
            self.env.pop(var, None)
        self.stub("pgrep", 'cat "$HOME/pids-$2" 2>/dev/null')
        self.stub("ps", "echo 1")
        self.stub("tmux", 'case "$1" in -V) echo stub;; list-clients) cat "$HOME/clients";; *) exit 1;; esac')
        self.stub("claude", 'printf "%s\\n" "$@" > "$HOME/claude-args"')
        self.stub("codex", 'printf "%s\\n" "$@" > "$HOME/codex-args"')
        self.stub("wt.exe", 'exit 1')
        for pid in ("10", "20", "30"):
            self.process(pid, "1", "", pg=pid)
        self.cwd = str(self.base / 'a directory; "quoted"')
        Path(self.cwd).mkdir()

    def stub(self, name, cmd):
        file = self.bin / name
        file.write_text("#!" + shutil.which("sh") + "\n" + cmd + "\n")
        file.chmod(0o755)

    def process(self, pid, ppid, pane, pg=None, fg=None, args=()):
        directory = self.proc / pid
        directory.mkdir(parents=True, exist_ok=True)
        (directory / "fd").mkdir(exist_ok=True)
        (directory / "cmdline").write_bytes(b"\0".join(a.encode() for a in args))
        (directory / "environ").write_bytes(f"WT_SESSION={pane}\0".encode())
        stat = ["S", ppid, pg or pid, "1", "2", fg or pg or pid] + ["0"] * 13 + [str(int(pid) * 3)]
        (directory / "stat").write_text(f"{pid} (a name with )) " + " ".join(stat))
        if not (directory / "cwd").exists():
            (directory / "cwd").symlink_to(self.base)

    def cli(self, *args, pane=A, pid="10", env=None):
        run = subprocess.run([CMD, *args], cwd=self.cwd, capture_output=True, text=True,
                             env=dict(self.env, WT_SESSION=pane, FLAKELAB_TYCSNAP_OWNER=pid, **(env or {})))
        self.assertEqual(run.returncode, 0, run.stderr)
        return run.stdout

    def state(self, op, *args, **kwargs):
        out = self.cli("--tab-state", op, *args, **kwargs)
        return json.loads(out) if out else None

    def panes(self):
        file = next((self.base / "claude/sessions").glob("*" + self.boot.read_text() + ".txt"))
        state = next(line[10:] for line in file.read_text().splitlines() if line.startswith("# tycsnap "))
        return json.loads(state)["panes"]

    def test_register_names_cwd_and_exit(self):
        self.assertEqual(self.state("enter"), {})
        self.cli("--restore-tab", "--name", "custom tab")
        self.assertEqual(self.cli("--tab-state", "update", self.cwd).strip(), "custom tab")
        self.cli("--restore-tab", "--name", "")
        self.assertEqual(self.panes()[A]["name"], "")
        self.cli("--restore-tab", "--name", "custom tab")
        self.assertEqual(self.panes()[A]["name"], "custom tab")
        self.assertEqual(self.panes()[A]["cwd"], self.cwd)
        self.state("exit")
        self.assertEqual(self.panes(), {})
        self.boot.write_text("bbbbbbbbbbbb")
        self.assertEqual(self.state("enter", pane=B), {})

    def test_restored_id_once_and_plain_tab_offer_once(self):
        self.state("enter")
        self.cli("--restore-tab", "--name", "saved title")
        self.boot.write_text("bbbbbbbbbbbb")
        envs = [(B, "20"), (C, "30")]
        with concurrent.futures.ThreadPoolExecutor() as pool:
            futures = [pool.submit(self.state, "enter", pane=p, pid=pid) for p, pid in envs]
            self.assertCountEqual([f.result() for f in futures], [{"action": "offer"}, {}])
        self.assertEqual(self.state("enter"), {"action": "restore", "cwd": self.cwd, "name": "saved title"})
        worker = str(os.getpid())
        self.assertEqual(self.state("take", worker)["name"], "saved title")
        self.assertEqual(self.state("take", worker), {"busy": True})
        self.state("finish", worker, "0")
        self.assertEqual(self.state("take", worker), {})
        self.assertEqual(self.state("reserve", pane=B, pid="20")["tokens"], [])

    def test_interop_token_one_shot_and_retry(self):
        self.state("enter")
        self.boot.write_text("bbbbbbbbbbbb")
        self.assertEqual(self.state("enter", pane=B), {"action": "offer"})
        token = f"aaaaaaaaaaaa/{A}"
        self.assertEqual(self.state("reserve", pane=B)["tokens"], [token])
        self.assertEqual(self.state("reserve", pane=B)["tokens"], [])
        self.assertEqual(self.state("reserve", "retry", pane=B)["tokens"], [token])
        self.state("release", token, pane=B)
        self.assertEqual(self.state("reserve", pane=B)["tokens"], [token])
        self.assertEqual(self.state("enter", pane=C, env={"FLAKELAB_TYCSNAP_SOURCE": token})["action"], "restore")
        self.assertEqual(self.state("reserve", pane=B)["tokens"], [])
        self.assertEqual(self.state("enter", pane=A, pid="20"), {})
        duplicate = self.state("enter", pane="eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee", pid="30",
                               env={"FLAKELAB_TYCSNAP_SOURCE": token})
        self.assertEqual(duplicate, {"action": "superseded"})

    def test_terminal_replays_fallback_startup_command_after_next_reboot(self):
        self.state("enter")
        self.boot.write_text("bbbbbbbbbbbb")
        self.state("enter", pane=B)
        token, = self.state("reserve", pane=B)["tokens"]
        source = {"FLAKELAB_TYCSNAP_SOURCE": token}
        self.state("enter", pane=C, pid="30", env=source)
        self.cli("--restore-tab", "--name", "new name", pane=C, pid="30")
        self.boot.write_text("cccccccccccc")
        restored = self.state("enter", pane=C, pid="30", env=source)
        self.assertEqual(restored, {"action": "restore", "cwd": self.cwd, "name": "new name"})

    def open_saved_request(self):
        saved = self.base / "manual.txt"
        saved.write_text(f"claude  {self.cwd}  {SID}\n")
        self.stub("wt.exe", 'printf "%s\\n" "$@" > "$HOME/wt-args"')
        self.cli("--open", str(saved))
        argv = (self.home / "wt-args").read_text().splitlines()
        self.assertEqual(argv[:10], ["-w", "0", "new-tab", "wsl.exe", "-d", "test", "--shell-type", "login", "--", "env"])
        self.assertEqual(argv[11:], ["zsh", "-il"])
        self.assertNotIn(self.cwd, argv)
        key, token = argv[10].split("=", 1)
        self.assertEqual(key, "FLAKELAB_TYCSNAP_SOURCE")
        return {key: token}

    def test_open_bootstraps_native_session_then_restores_its_edited_pane(self):
        self.stub("tmux", "exit 1")
        source = self.open_saved_request()
        entry = self.state("enter", env=source)
        self.assertEqual(entry, {"action": "restore", "cwd": self.cwd, "name": Path(self.cwd).name})
        self.cli("--restore-tab")
        self.assertEqual((self.home / "claude-args").read_text().splitlines(), ["--resume", SID])
        self.cli("--restore-tab", "--name", "edited")
        self.boot.write_text("bbbbbbbbbbbb")
        self.assertEqual(self.state("enter", env=source)["name"], "edited")

    def test_open_reattaches_the_same_live_tmux_window_after_reopen(self):
        self.process("303", "1", "", args=["tmux", "server"])
        self.stub("tmux", """
printf '%s\\n' "$*" >> "$HOME/tmux-log"
case "$1" in
  -V|has-session|set-hook|select-window|list-panes|list-sessions) exit 0;;
  new-window) echo '@7';;
  new-session) exit 0;;
  attach-session) printf '%s\\n' "$3" > "$HOME/attached";;
  display-message)
    case "$5" in
      '#{pid}') echo 303;;
      '#{session_name}') echo agents;;
      '#{window_id}') if [ "$4" = '@7' ] || [ ! -e "$HOME/attached" ]; then echo '@7'; fi;;
    esac;;
  *) exit 1;;
esac
""")
        source = self.open_saved_request()
        self.state("enter", env=source)
        self.cli("--restore-tab")
        first = (self.home / "attached").read_text()
        self.assertTrue(first.startswith("agents-7-"))
        (self.proc / "10/stat").unlink()
        entry = self.state("enter", pid="20", env=source)
        self.assertEqual(entry["action"], "restore")
        self.cli("--restore-tab", pid="20")
        self.assertNotEqual((self.home / "attached").read_text(), first)
        log = (self.home / "tmux-log").read_text().splitlines()
        self.assertEqual(sum(line.startswith("new-window ") for line in log), 1)
        self.assertEqual(sum(line.startswith("attach-session ") for line in log), 2)
        self.assertFalse((self.home / "claude-args").exists())

    def test_mistaken_tab_close_this_boot(self):
        self.state("enter")
        self.state("enter", pane=B, pid="20")
        self.assertEqual(self.state("available", pane=B, pid="20")["tokens"], [])
        (self.proc / "10/stat").unlink()
        token = f"aaaaaaaaaaaa/{A}"
        self.assertEqual(self.state("reserve", pane=B, pid="20")["tokens"], [token])
        self.assertEqual(self.state("enter", pane=C, pid="30", env={"FLAKELAB_TYCSNAP_SOURCE": token})["action"], "restore")
        self.assertNotIn(A, self.panes())

    def test_direct_native_sessions_and_background_noise(self):
        self.state("enter")
        self.state("enter", pane=B, pid="20")
        self.process("101", "10", A, args=["claude"])
        reg = self.home / ".claude/sessions"
        reg.mkdir(parents=True)
        (reg / "101.json").write_text(json.dumps(dict(sessionId=SID)))
        self.process("102", "10", A, pg="102", fg="101", args=["claude"])
        (reg / "102.json").write_text(json.dumps(dict(sessionId=C)))
        (self.home / "pids-claude").write_text("101\n102")
        self.process("202", "20", B, args=["codex", "resume", C])
        (self.home / "pids-codex").write_text("202")
        self.cli("--autosave")
        self.assertEqual(self.panes()[A]["agent"]["session"], SID)
        self.assertEqual(self.panes()[B]["agent"]["session"], C)
        # A foreground we cannot identify cannot inherit the last agent's id.
        self.process("102", "10", A, pg="101", fg="101", args=["claude"])
        self.cli("--autosave")
        self.assertNotIn("agent", self.panes()[A])
        self.process("102", "10", A, pg="102", fg="101", args=["claude"])
        self.cli("--autosave")
        self.boot.write_text("bbbbbbbbbbbb")
        (self.home / "pids-claude").unlink()
        (self.home / "pids-codex").unlink()
        for pane, pid, tool, command, sid in [(A, "10", "claude", "--resume", SID), (B, "20", "codex", "resume", C)]:
            self.state("enter", pane=pane, pid=pid)
            if tool == "claude":
                self.stub(tool, "exit 27")
                failed = subprocess.run([CMD, "--restore-tab"], cwd=self.cwd, capture_output=True,
                                        env=dict(self.env, WT_SESSION=pane, FLAKELAB_TYCSNAP_OWNER=pid))
                self.assertEqual(failed.returncode, 27)
                self.cli("--tab-state", "update", self.cwd, pane=pane, pid=pid)
                self.assertTrue(self.panes()[A]["pending"])
                self.stub(tool, 'printf "%s\\n" "$@" > "$HOME/claude-args"')
            self.cli("--restore-tab", pane=pane, pid=pid)
            self.assertNotIn("pending", self.panes()[pane])
            self.assertEqual((self.home / f"{tool}-args").read_text().splitlines(), [command, sid])

    def test_tmux_client_wins_over_inherited_old_tab_environment(self):
        self.state("enter")
        self.state("enter", pane=B, pid="20")
        self.process("303", "1", A, args=["tmux", "server"])
        self.process("304", "20", B, args=["tmux", "attach"])
        self.process("305", "303", A, args=["claude"])
        self.stub("tmux", 'case "$1" in -V) echo tmux;; list-clients) cat "$HOME/clients";; list-panes) cat "$HOME/panes";; *) exit 1;; esac')
        (self.home / "clients").write_text(US.join(["304", "303", "agents", "@4", "review", "305"]))
        (self.home / "panes").write_text(US.join(["305", "agents", "@4", "review", ""]) + "\n")
        reg = self.home / ".claude/sessions"
        reg.mkdir(parents=True)
        (reg / "305.json").write_text(json.dumps(dict(sessionId=SID)))
        (self.home / "pids-claude").write_text("305")
        self.cli("--autosave")
        panes = self.panes()
        self.assertNotIn("agent", panes[A])
        self.assertEqual(panes[B]["agent"]["session"], SID)
        self.assertEqual(panes[B]["tmux"]["window"], "@4")
        (self.home / "clients").write_text(US.join(["304", "303", "agents", "@7", "shell", "400"]))
        self.cli("--autosave")
        self.assertNotIn("agent", self.panes()[B])
        self.assertEqual(self.panes()[B]["tmux"]["window"], "@7")


if __name__ == "__main__":
    unittest.main()
