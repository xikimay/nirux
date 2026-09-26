import Darwin
import XCTest
@testable import Nirux

final class LocalServerProposalTests: XCTestCase {
    private typealias Book = LocalServerProposalBook<String>

    private func url(_ port: Int, host: String = "localhost", path: String = "/") -> LocalServerURL {
        LocalServerURL(isSecure: false, host: host, port: port, path: path)
    }

    private func scan(
        _ book: inout Book,
        listening: Set<Int>,
        browser: Set<Int> = [],
        columns: Set<String> = ["term"],
        at now: TimeInterval = 1
    ) {
        book.applyScan(listeningPorts: listening, browserPorts: browser, liveColumns: columns, now: now)
    }

    private func propose(_ book: inout Book, _ server: LocalServerURL, in column: String = "term") {
        XCTAssertTrue(book.noteDetected(server, in: column, browserPorts: [], now: 0))
        // Servers proposed earlier are still up.
        XCTAssertTrue(book.applyScan(
            listeningPorts: Set(book.proposals.map(\.url.port)).union([server.port]),
            browserPorts: [],
            liveColumns: [column, "term", "api", "web", "other"],
            now: 0.3
        ))
    }

    // MARK: - Detection → scan

    func testListeningServerBecomesTheColumnsProposal() {
        var book = Book()
        propose(&book, url(5173))
        XCTAssertEqual(book.proposal(for: "term")?.url, url(5173))
        XCTAssertNil(book.proposal(for: "other"))
        XCTAssertTrue(book.pending.isEmpty)
    }

    func testOneProposalPerPort() {
        var book = Book()
        XCTAssertTrue(book.noteDetected(url(3000), in: "term", browserPorts: [], now: 0))
        // Same port again before the scan — "Local" + "Network", 127.0.0.1 vs localhost.
        XCTAssertFalse(book.noteDetected(url(3000, host: "127.0.0.1"), in: "term", browserPorts: [], now: 0.1))
        scan(&book, listening: [3000])
        // ...and once proposed, even from another terminal.
        XCTAssertFalse(book.noteDetected(url(3000), in: "other", browserPorts: [], now: 2))
        XCTAssertEqual(book.proposals.count, 1)
    }

    func testDetectionWaitsForItsPortThenExpires() {
        var book = Book()
        XCTAssertTrue(book.noteDetected(url(8000), in: "term", browserPorts: [], now: 10))
        XCTAssertEqual(book.nextScanDelay, Book.pendingScanInterval)
        scan(&book, listening: [], at: 10.3)
        scan(&book, listening: [], at: 11.3)
        XCTAssertNotNil(book.pending[8000])
        scan(&book, listening: [], at: 10 + Book.pendingWindow)
        XCTAssertTrue(book.pending.isEmpty)
        XCTAssertTrue(book.proposals.isEmpty)
        XCTAssertNil(book.nextScanDelay)
        // A later print (server restarted) starts over.
        XCTAssertTrue(book.noteDetected(url(8000), in: "term", browserPorts: [], now: 20))
    }

    func testServerThatBindsAfterPrintingIsProposed() {
        var book = Book()
        XCTAssertTrue(book.noteDetected(url(8000), in: "term", browserPorts: [], now: 0))
        scan(&book, listening: [], at: 0.3)
        scan(&book, listening: [8000], at: 1.3)
        XCTAssertEqual(book.proposal(for: "term")?.url.port, 8000)
        XCTAssertEqual(book.nextScanDelay, Book.livenessScanInterval)
    }

    func testOneScanResolvesEveryPendingPortNewestFirst() {
        var book = Book()
        XCTAssertTrue(book.noteDetected(url(3000), in: "term", browserPorts: [], now: 0))
        XCTAssertTrue(book.noteDetected(url(5173), in: "term", browserPorts: [], now: 0.1))
        scan(&book, listening: [3000, 5173])
        XCTAssertEqual(book.proposals.map(\.url.port), [5173, 3000])
    }

    func testPendingDetectionsAreCapped() {
        var book = Book()
        for port in 1...Book.maxPending {
            XCTAssertTrue(book.noteDetected(url(port), in: "term", browserPorts: [], now: 0))
        }
        XCTAssertFalse(book.noteDetected(url(9999), in: "term", browserPorts: [], now: 0))
    }

    // MARK: - Browser columns

    func testPortAlreadyShownInABrowserColumnIsNotProposed() {
        var book = Book()
        XCTAssertFalse(book.noteDetected(url(5173), in: "term", browserPorts: [5173], now: 0))
        // A browser column opened on the port before the scan.
        XCTAssertTrue(book.noteDetected(url(3000), in: "term", browserPorts: [], now: 0))
        scan(&book, listening: [3000], browser: [3000])
        XCTAssertTrue(book.proposals.isEmpty)
        XCTAssertTrue(book.pending.isEmpty)
    }

    func testBrowserColumnOnThePortPrunesTheProposal() {
        var book = Book()
        propose(&book, url(5173))
        XCTAssertTrue(book.liveProposals(browserPorts: [5173], liveColumns: ["term"]).isEmpty)
        XCTAssertTrue(book.prune(browserPorts: [5173], liveColumns: ["term"]))
        XCTAssertNil(book.proposal(for: "term"))
    }

    // MARK: - User actions

    func testHandledPortIsNeverProposedAgain() {
        var book = Book()
        propose(&book, url(5173))
        propose(&book, url(3000))
        // Dismissed...
        book.markHandled(port: 5173)
        // ...or opened: TUIs keep repainting the URL, so neither may come back.
        book.markHandled(port: 3000)
        XCTAssertNil(book.proposal(for: "term"))
        XCTAssertFalse(book.noteDetected(url(5173), in: "term", browserPorts: [], now: 5))
        XCTAssertFalse(book.noteDetected(url(3000), in: "other", browserPorts: [], now: 5))
        XCTAssertNil(book.nextScanDelay)
    }

    // MARK: - Liveness + columns

    func testStoppedServerIsRemovedAfterItsGracePeriod() {
        var book = Book()
        propose(&book, url(3000))
        propose(&book, url(5173))
        // A restart unbinds the port briefly: the grace period forgives it.
        XCTAssertFalse(book.applyScan(listeningPorts: [5173], browserPorts: [], liveColumns: ["term"], now: 3))
        XCTAssertFalse(book.applyScan(listeningPorts: [3000, 5173], browserPorts: [], liveColumns: ["term"], now: 6))
        XCTAssertFalse(book.applyScan(listeningPorts: [5173], browserPorts: [], liveColumns: ["term"], now: 9))
        XCTAssertTrue(book.applyScan(
            listeningPorts: [5173], browserPorts: [], liveColumns: ["term"], now: 9 + Book.removalGrace
        ))
        XCTAssertEqual(book.proposals.map(\.url.port), [5173])
    }

    func testGraceIsTimeBasedWhenScansRunFast() {
        var book = Book()
        propose(&book, url(3000))
        // A pending detection makes scans run every second.
        XCTAssertTrue(book.noteDetected(url(8000), in: "term", browserPorts: [], now: 10))
        for now in [10.3, 11.3, 12.3] {
            book.applyScan(listeningPorts: [], browserPorts: [], liveColumns: ["term"], now: now)
            XCTAssertEqual(book.proposals.map(\.url.port), [3000], "removed too early at \(now)")
        }
        book.applyScan(listeningPorts: [], browserPorts: [], liveColumns: ["term"], now: 10.3 + Book.removalGrace)
        XCTAssertTrue(book.proposals.isEmpty)
    }

    func testClosedTerminalDropsItsProposalsAndPendingDetections() {
        var book = Book()
        propose(&book, url(3000), in: "gone")
        XCTAssertTrue(book.noteDetected(url(4000), in: "gone", browserPorts: [], now: 1))
        XCTAssertTrue(book.liveProposals(browserPorts: [], liveColumns: ["term"]).isEmpty)
        XCTAssertTrue(book.prune(browserPorts: [], liveColumns: ["term"]))
        XCTAssertTrue(book.proposals.isEmpty)
        XCTAssertTrue(book.pending.isEmpty)
        XCTAssertNil(book.nextScanDelay)
    }

    func testEachColumnShowsItsMostRecentProposal() {
        var book = Book()
        propose(&book, url(3000), in: "api")
        propose(&book, url(5173), in: "web")
        propose(&book, url(6006), in: "web")
        XCTAssertEqual(book.proposal(for: "api")?.url.port, 3000)
        XCTAssertEqual(book.proposal(for: "web")?.url.port, 6006)
        // ⌘B lists everything, most recent first.
        XCTAssertEqual(
            book.liveProposals(browserPorts: [], liveColumns: ["api", "web"]).map(\.url.port),
            [6006, 5173, 3000]
        )
        // Handling the chip reveals the column's previous proposal.
        book.markHandled(port: 6006)
        XCTAssertEqual(book.proposal(for: "web")?.url.port, 5173)
    }

    // MARK: - ⌘B suggestions

    func testURLSuggestionsListDetectedFirstWithoutDuplicates() {
        let suggestions = CommandPalette.urlSuggestions(
            detected: ["http://localhost:5173/"],
            history: ["https://github.com", "http://localhost:5173", "http://localhost:3000"],
            defaults: ["http://localhost:3000", "http://localhost:8080"]
        )
        XCTAssertEqual(suggestions, [
            "http://localhost:5173/",
            "https://github.com",
            "http://localhost:3000",
            "http://localhost:8080"
        ])
    }

    // MARK: - Listener scan

    func testListenerScanSeesALoopbackListenerAndItsClosing() throws {
        let (fd, port) = try listen(family: AF_INET)
        XCTAssertTrue(LocalListeners.listeningPorts().contains(port))
        close(fd)
        XCTAssertFalse(LocalListeners.listeningPorts().contains(port))
    }

    func testListenerScanSeesIPv6Listeners() throws {
        let (fd, port) = try listen(family: AF_INET6)
        defer { close(fd) }
        XCTAssertTrue(LocalListeners.listeningPorts().contains(port))
    }

    func testSystemServicesAreNotDevServers() {
        // AirPlay Receiver holds :5000 and :7000.
        XCTAssertTrue(LocalListeners.isSystemExecutable(
            "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter"
        ))
        XCTAssertTrue(LocalListeners.isSystemExecutable("/usr/libexec/rapportd"))
        XCTAssertFalse(LocalListeners.isSystemExecutable("/opt/homebrew/Cellar/node/22.0.0/bin/node"))
        XCTAssertFalse(LocalListeners.isSystemExecutable("/usr/local/bin/php"))
        // The system Ruby can still serve a Jekyll site.
        XCTAssertFalse(LocalListeners.isSystemExecutable(
            "/System/Library/Frameworks/Ruby.framework/Versions/2.6/usr/bin/ruby"
        ))
    }

    /// A loopback listener on an ephemeral port.
    private func listen(family: Int32) throws -> (fd: Int32, port: Int) {
        let fd = socket(family, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw XCTSkip("socket() failed: \(errno)") }
        var bound: Int32
        if family == AF_INET {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
            bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        } else {
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_addr = in6addr_loopback
            bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        }
        guard bound == 0, Darwin.listen(fd, 4) == 0 else {
            close(fd)
            throw XCTSkip("loopback bind/listen unavailable: \(errno)")
        }
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        _ = withUnsafeMutablePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        let port: UInt16 = withUnsafePointer(to: &storage) { pointer in
            family == AF_INET
                ? pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_port }
                : pointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_port }
        }
        return (fd, Int(UInt16(bigEndian: port)))
    }
}
