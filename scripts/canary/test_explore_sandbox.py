from pathlib import Path
import subprocess
import tempfile
import unittest

from run import environment

HERE = Path(__file__).resolve().parent
REAL_KNOWN_HOSTS = Path.home() / ".ssh/known_hosts"


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

    def test_no_network_but_localhost(self):
        outside = confined(self.work, "/usr/bin/curl", "-sS", "--max-time", "5", "https://1.1.1.1")
        self.assertNotEqual(outside.returncode, 0)
        git = confined(self.work, "/usr/bin/git", "-C", str(self.work), "init", "-q", "repo")
        self.assertEqual(git.returncode, 0, git.stderr)


if __name__ == "__main__":
    unittest.main()
