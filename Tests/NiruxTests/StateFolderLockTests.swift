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

    private func holder(_ outcome: StateFolderLock.Outcome, file: StaticString = #filePath, line: UInt = #line) -> StateFolderLock.Holder? {
        guard case .held(let holder) = outcome else {
            XCTFail("not held by another: \(outcome)", file: file, line: line)
            return nil
        }
        return holder
    }

    private var lockText: String? {
        try? String(contentsOf: folder.appendingPathComponent(StateFolderLock.fileName), encoding: .utf8)
    }

    /// The first takes it and says who it is. A second on the same folder is
    /// told at once who holds it, while that one runs; once it lets go, the
    /// next one takes it and writes over a longer line.
    func testOneHolderPerFolder() throws {
        let first = try XCTUnwrap(acquired(StateFolderLock.acquire(in: folder, wait: 0, pid: 4242)))
        XCTAssertEqual(lockText, "4242\n")
        let started = Date()
        XCTAssertEqual(holder(StateFolderLock.acquire(in: folder, wait: 5, pid: 99) { _ in true }), .init(pid: 4242, isQuitting: false))
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "a Nirux that runs is no reason to wait")
        // Another folder has its own.
        let other = folder.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        acquired(StateFolderLock.acquire(in: other, wait: 0))?.release()
        first.markQuitting()
        XCTAssertEqual(lockText, "4242 quitting\n")
        first.release()
        let next = try XCTUnwrap(acquired(StateFolderLock.acquire(in: folder, wait: 0, pid: 99)))
        XCTAssertEqual(lockText, "99\n", "nothing left of the longer line")
        next.release()
    }

    /// A Nirux that is quitting (a quick reopen; Sparkle relaunches the app
    /// once it is gone) is waited for: the new one takes over when it lets
    /// go, or is told who holds it at the end of the wait.
    func testItWaitsForAHolderThatIsQuitting() throws {
        let quitting = try XCTUnwrap(acquired(StateFolderLock.acquire(in: folder, wait: 0, pid: 4242)))
        quitting.markQuitting()
        let started = Date()
        XCTAssertEqual(holder(StateFolderLock.acquire(in: folder, wait: 0.4) { _ in true }), .init(pid: 4242, isQuitting: true))
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.4)
        let descriptor = quitting.descriptor
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { close(descriptor) }
        acquired(StateFolderLock.acquire(in: folder, wait: 5) { _ in true })?.release()
    }

    /// A holder whose pid doesn't run, or that wrote nothing readable, is
    /// waited for too: it may be on its way out.
    func testItWaitsForAnUnknownHolder() throws {
        let first = try XCTUnwrap(acquired(StateFolderLock.acquire(in: folder, wait: 0, pid: 4242)))
        let started = Date()
        XCTAssertEqual(holder(StateFolderLock.acquire(in: folder, wait: 0.4) { _ in false }), .init(pid: 4242, isQuitting: false))
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.4)
        first.release()
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
