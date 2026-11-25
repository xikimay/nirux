import os
from pathlib import Path
import socket
import subprocess
import tempfile
import unittest

from run import environment

HERE = Path(__file__).resolve().parent
REAL_KNOWN_HOSTS = Path.home() / ".ssh/known_hosts"
# A private pasteboard named by its first argument: prints its text, sets it to the second
# argument, or releases it with --release. Never the user's clipboard.
BOARD = """import AppKit
let board = NSPasteboard(name: NSPasteboard.Name(CommandLine.arguments[1]))
switch CommandLine.arguments.dropFirst(2).first {
case "--release"?: board.releaseGlobally()
case let text?: board.clearContents(); board.setString(text, forType: .string)
case nil: print(board.string(forType: .string) ?? "")
}
"""
# Whether Finder could be automated, never asking the user: 0, or -1744 (would ask); -600 when the
# sender may not send AppleEvents at all.
AUTOMATION = """import Foundation
import CoreServices
let finder = NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder")
print(AEDeterminePermissionToAutomateTarget(finder.aeDesc!, typeWildCard, typeWildCard, false))
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

    def build(self, name, source):
        (self.work / f"{name}.swift").write_text(source)
        subprocess.run(["/usr/bin/swiftc", "-O", f"{name}.swift", "-o", name], cwd=self.work, check=True, timeout=180)
        return f"./{name}"

    def test_no_pasteboard_reaches_the_copy(self):
        board, name = self.build("board", BOARD), f"canary-test-{self.work.name}"
        marker = f"marker-{self.work.name}"
        run = lambda *args: subprocess.run([board, *args], cwd=self.work, capture_output=True, text=True, timeout=10)
        run(name, marker)
        try:
            self.assertEqual(run(name).stdout.strip(), marker, "outside the copy, the pasteboard answers")
            self.assertNotIn(marker, confined(self.work, board, name).stdout)
            confined(self.work, board, name, "overwritten")
            self.assertEqual(run(name).stdout.strip(), marker)
        finally:
            run(name, "--release")

    def test_no_appleevents(self):
        automation = self.build("automation", AUTOMATION)
        plain = subprocess.run([automation], cwd=self.work, capture_output=True, text=True, timeout=10).stdout.strip()
        if plain == "-600":
            self.skipTest("Finder isn't running: nothing to tell the sandbox's refusal from")
        self.assertEqual(confined(self.work, automation).stdout.strip(), "-600", f"outside the copy: {plain}")

    def test_no_outside_socket_no_launchd_tool(self):
        ready = confined(self.work, "/usr/bin/python3", "-c", "print('ready')")
        self.assertEqual((ready.returncode, ready.stdout.strip()), (0, "ready"), ready.stderr)
        listener = socket.socket(socket.AF_UNIX)
        listener.bind(str(self.outside / "agent.sock"))
        listener.listen(1)
        try:
            reach = confined(self.work, "/usr/bin/python3", "-c", "import socket,sys; socket.socket(socket.AF_UNIX).connect(sys.argv[1])",
                             str(self.outside / "agent.sock"))
            self.assertNotEqual(reach.returncode, 0, "a socket outside the run folder")
            self.assertIn("PermissionError", reach.stderr)
        finally:
            listener.close()
        for tool in (["/bin/launchctl", "print", "system"], ["/usr/bin/osascript", "-e", "return 1"], ["/usr/bin/open", "-Ra", "Finder"]):
            self.assertNotEqual(confined(self.work, *tool).returncode, 0, tool[0])

    def test_only_xcruns_own_cache_in_the_user_temp_folder(self):
        temp = Path(os.path.realpath(subprocess.check_output(["/usr/bin/getconf", "DARWIN_USER_TEMP_DIR"], text=True).strip()))
        lookalike = temp / f"xcrun_db-{self.work.name.replace('-', '').replace('_', '')}"
        lookalike.mkdir()
        try:
            (lookalike / "secret").write_text("secret\n")
            self.assertNotIn("secret", confined(self.work, "/bin/cat", str(lookalike / "secret")).stdout)
        finally:
            subprocess.run(["/bin/rm", "-rf", str(lookalike)], check=True)

    def test_no_network_but_localhost(self):
        outside = confined(self.work, "/usr/bin/curl", "-sS", "--max-time", "5", "https://1.1.1.1")
        self.assertNotEqual(outside.returncode, 0)
        git = confined(self.work, "/usr/bin/git", "-C", str(self.work), "init", "-q", "repo")
        self.assertEqual(git.returncode, 0, git.stderr)


if __name__ == "__main__":
    unittest.main()
