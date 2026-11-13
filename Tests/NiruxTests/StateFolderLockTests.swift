import XCTest
@testable import Nirux

/// One Nirux per state folder (see StateFolderLock). flock locks belong to
/// an open file, so two opens in one process stand for two Niruxes.
final class StateFolderLockTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-lock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    private func acquired(_ outcome: StateFolderLock.Outcome, file: StaticString = #filePath, line: UInt = #line) -> StateFolderLock? {
        guard case .acquired(let lock) = outcome else {
            XCTFail("not acquired: \(outcome)", file: file, line: line)
            return nil
        }
        return lock
    }

    /// The first takes it and says who it is; a second on the same folder
    /// is told who holds it; once the first lets go, the next one takes it.
    func testOneHolderPerFolder() throws {
        let first = try XCTUnwrap(acquired(StateFolderLock.acquire(in: folder, wait: 0, pid: 4242)))
        guard case .held(let holder) = StateFolderLock.acquire(in: folder, wait: 0, pid: 99) else {
            return XCTFail("a second one got the lock")
        }
        XCTAssertEqual(holder, 4242)
        // Another folder has its own.
        let other = folder.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        acquired(StateFolderLock.acquire(in: other, wait: 0))?.release()
        first.release()
        let next = try XCTUnwrap(acquired(StateFolderLock.acquire(in: folder, wait: 0, pid: 99)))
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent(StateFolderLock.fileName), encoding: .utf8), "99\n")
        next.release()
    }

    /// A Nirux that is quitting (Sparkle relaunches the app once it is
    /// gone) lets go within the wait: the new one takes over.
    func testItWaitsForAHolderThatIsQuitting() throws {
        let quitting = try XCTUnwrap(acquired(StateFolderLock.acquire(in: folder, wait: 0)))
        let descriptor = quitting.descriptor
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { close(descriptor) }
        acquired(StateFolderLock.acquire(in: folder, wait: 5))?.release()
    }

    /// The processes Nirux starts (its terminals' shells, forked and
    /// exec'd) don't keep the lock: agents still running after Nirux quit
    /// don't stop the next one from opening.
    func testTheProcessesItStartsDontKeepIt() throws {
        let lock = try XCTUnwrap(acquired(StateFolderLock.acquire(in: folder, wait: 0)))
        var child: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sleep"), strdup("5"), nil]
        let envp: [UnsafeMutablePointer<CChar>?] = [nil]
        defer { argv.forEach { free($0) } }
        XCTAssertEqual(posix_spawn(&child, "/bin/sleep", nil, nil, argv, envp), 0)
        defer {
            kill(child, SIGKILL)
            waitpid(child, nil, 0)
        }
        lock.release()
        acquired(StateFolderLock.acquire(in: folder, wait: 0))?.release()
    }

    /// A folder it can't write: Nirux opens as it did before the lock.
    func testAnUnwritableFolderDoesntStopNirux() {
        guard case .unavailable = StateFolderLock.acquire(in: folder.appendingPathComponent("missing"), wait: 0) else {
            return XCTFail("a lock in a folder that isn't there")
        }
    }
}
