from pathlib import Path
import socket
import subprocess
import tempfile
import unittest

from run import environment

HERE = Path(__file__).resolve().parent
REAL_KNOWN_HOSTS = Path.home() / ".ssh/known_hosts"
# Prints the clipboard's text, or replaces it with its argument.
BOARD = """import AppKit
let board = NSPasteboard.general
if CommandLine.arguments.count > 1 {
    board.clearContents()
    board.setString(CommandLine.arguments[1], forType: .string)
} else {
    print(board.string(forType: .string) ?? "")
}
"""


def confined(work, *command):
    """`command` under explore.sb, as the explorer's copy and its children run (run.environment)."""
    for name in ("tmp", "home"):
        (work / name).mkdir(exist_ok=True)
    return subprocess.run(["/usr/bin/sandbox-exec", "-f", str(HERE / "explore.sb"), "-D", f"WORK={work}", *command],
                          cwd=work, env=environment(work), capture_output=True, text=True, timeout=30)


@unittest.skipUnless(Path("/usr/bin/sandbox-exec").exists(), "macOS sandbox")
class ExploreSandboxTests(unittest.TestCase):
    def setUp(self):
        self.work = Path(tempfile.mkdtemp(dir="/private/tmp", prefix="nirux-canary-test-")).resolve()
        self.outside = Path(tempfile.mkdtemp()).resolve()
        (self.outside / "secret").write_text("secret\n")
        (self.work / "mine").write_text("mine\n")

    def tearDown(self):
        for folder in (self.work, self.outside):
            subprocess.run(["/bin/rm", "-rf", str(folder)], check=True)

    def test_a_shell_in_the_copy_reads_and_writes_only_the_run_folder(self):
        shell = confined(self.work, "/bin/zsh", "-fc",
                         f"cat mine && echo new > new && cat {self.outside}/secret; ls {self.outside}; "
                         f"echo leak > {self.outside}/leak; cat ~/.ssh/known_hosts")
        self.assertIn("mine", shell.stdout)
        self.assertEqual((self.work / "new").read_text(), "new\n")
        self.assertNotIn("secret", shell.stdout)
        self.assertFalse((self.outside / "leak").exists())
        if REAL_KNOWN_HOSTS.is_file():
            known = confined(self.work, "/bin/cat", str(REAL_KNOWN_HOSTS))
            self.assertNotEqual(known.returncode, 0)
            self.assertEqual(known.stdout, "")
            self.assertIn("Operation not permitted", known.stderr)

    def test_no_clipboard_no_outside_socket_no_launchd_tool(self):
        marker = f"canary-clipboard-{self.work.name}"
        outside_copy = subprocess.run(["/usr/bin/pbcopy"], input=marker, text=True, timeout=10)
        self.assertEqual(outside_copy.returncode, 0)
        try:
            # The copy can neither read the user's clipboard nor write it, by any program: one built
            # here (pbcopy and pbpaste can't even start) finds no pasteboard.
            (self.work / "board.swift").write_text(BOARD)
            subprocess.run(["/usr/bin/swiftc", "-O", "board.swift", "-o", "board"], cwd=self.work, check=True, timeout=120)
            self.assertEqual(subprocess.run([self.work / "board"], capture_output=True, text=True).stdout.strip(), marker)
            self.assertNotIn(marker, confined(self.work, "./board").stdout)
            confined(self.work, "./board", "overwritten")
            self.assertEqual(subprocess.run(["/usr/bin/pbpaste"], capture_output=True, text=True).stdout, marker)
        finally:
            subprocess.run(["/usr/bin/pbcopy"], input="", text=True, timeout=10)
        listener = socket.socket(socket.AF_UNIX)
        listener.bind(str(self.outside / "agent.sock"))
        listener.listen(1)
        try:
            reach = confined(self.work, "/usr/bin/python3", "-c", "import socket,sys; socket.socket(socket.AF_UNIX).connect(sys.argv[1])",
                             str(self.outside / "agent.sock"))
            self.assertNotEqual(reach.returncode, 0, "a socket outside the run folder")
        finally:
            listener.close()
        for tool in (["/bin/launchctl", "print", "system"], ["/usr/bin/osascript", "-e", "return 1"], ["/usr/bin/open", "-Ra", "Finder"]):
            self.assertNotEqual(confined(self.work, *tool).returncode, 0, tool[0])

    def test_no_network_but_localhost(self):
        outside = confined(self.work, "/usr/bin/curl", "-sS", "--max-time", "5", "https://1.1.1.1")
        self.assertNotEqual(outside.returncode, 0)
        git = confined(self.work, "/usr/bin/git", "-C", str(self.work), "init", "-q", "repo")
        self.assertEqual(git.returncode, 0, git.stderr)


if __name__ == "__main__":
    unittest.main()
