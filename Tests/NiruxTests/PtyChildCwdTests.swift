import Darwin
import XCTest
@testable import Nirux

/// A terminal's working directory is read live from its shell. Between
/// `forkpty` and the child's `chdir`, that is still Nirux's own: an editor
/// column opened then rooted its file picker in the checkout running the
/// tests (`SidebarPanelFlowTests.testEditorFilePicker` on a slow runner).
@MainActor
final class PtyChildCwdTests: XCTestCase {
    func testAShellReportsItsWorkingDirectoryOnlyOnceItHasExeced() throws {
        // A shell caught between `forkpty` and `chdir`: forked, never exec'd.
        var fd: Int32 = -1
        let forked = forkpty(&fd, nil, nil, nil)
        // `alarm` ends it should this process die before the defer runs.
        if forked == 0 { alarm(60); while true { pause() } }
        // Never past here with -1: kill(-1) signals every process we own.
        guard forked > 0 else { return XCTFail("forkpty failed: errno \(errno)") }
        defer {
            kill(forked, SIGKILL)
            waitpid(forked, nil, 0)
            close(fd)
        }
        XCTAssertNil(PtySession.cwd(ofExecedProcess: forked))

        // Once exec'd, the folder `start` gave it: a scratch one, which
        // NIRUX_STATE_DIR points at, like every test that starts a real shell.
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-pty-cwd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let previousStateDirectory = ProcessInfo.processInfo.environment["NIRUX_STATE_DIR"]
        setenv("NIRUX_STATE_DIR", scratch.path, 1)
        defer {
            if let previousStateDirectory {
                setenv("NIRUX_STATE_DIR", previousStateDirectory, 1)
            } else {
                unsetenv("NIRUX_STATE_DIR")
            }
            try? FileManager.default.removeItem(at: scratch)
        }
        let folder = try XCTUnwrap(scratch.path.realPath)
        let shell = PtySession()
        shell.start(shell: "/bin/sh", args: ["-c", "sleep 30"], cwd: folder)
        let deadline = Date().addingTimeInterval(10)
        while shell.childCwd == nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(shell.childCwd, folder)
    }
}
