import Darwin
import XCTest
@testable import Nirux

final class LocalServerProposalTests: XCTestCase {
    private typealias Book = LocalServerProposalBook<String>

    private func url(_ port: Int, host: String = "localhost", path: String = "/") -> LocalServerURL {
        LocalServerURL(isSecure: false, host: host, port: port, path: path)
    }

    private func propose(_ book: inout Book, _ server: LocalServerURL, in column: String = "term") {
        XCTAssertTrue(book.noteDetected(server, in: column, browserPorts: []))
        XCTAssertEqual(
            book.probeFinished(port: server.port, isListening: true, browserPorts: [], liveColumns: [column]),
            .proposed
        )
    }

    // MARK: - Detection → probe

    func testListeningServerBecomesTheColumnsProposal() {
        var book = Book()
        propose(&book, url(5173))
        XCTAssertEqual(book.proposal(for: "term")?.url, url(5173))
        XCTAssertNil(book.proposal(for: "other"))
        XCTAssertTrue(book.pending.isEmpty)
    }

    func testOneProposalPerPort() {
        var book = Book()
        XCTAssertTrue(book.noteDetected(url(3000), in: "term", browserPorts: []))
        // Same port again while probing — "Local" + "Network" lines, 127.0.0.1 vs localhost.
        XCTAssertFalse(book.noteDetected(url(3000, host: "127.0.0.1"), in: "term", browserPorts: []))
        _ = book.probeFinished(port: 3000, isListening: true, browserPorts: [], liveColumns: ["term"])
        // ...and once proposed, even from another terminal.
        XCTAssertFalse(book.noteDetected(url(3000), in: "other", browserPorts: []))
        XCTAssertEqual(book.proposals.count, 1)
    }

    func testClosedPortIsRetriedThenDropped() {
        var book = Book()
        XCTAssertTrue(book.noteDetected(url(8000), in: "term", browserPorts: []))
        let delays = Book.probeDelays
        XCTAssertEqual(
            book.probeFinished(port: 8000, isListening: false, browserPorts: [], liveColumns: ["term"]),
            .retry(after: delays[1])
        )
        XCTAssertEqual(
            book.probeFinished(port: 8000, isListening: false, browserPorts: [], liveColumns: ["term"]),
            .retry(after: delays[2])
        )
        XCTAssertEqual(
            book.probeFinished(port: 8000, isListening: false, browserPorts: [], liveColumns: ["term"]),
            .dropped
        )
        XCTAssertTrue(book.pending.isEmpty)
        XCTAssertTrue(book.proposals.isEmpty)
        // A later print (server restarted) starts over.
        XCTAssertTrue(book.noteDetected(url(8000), in: "term", browserPorts: []))
    }

    func testRetryThatFindsTheServerProposesIt() {
        var book = Book()
        XCTAssertTrue(book.noteDetected(url(8000), in: "term", browserPorts: []))
        _ = book.probeFinished(port: 8000, isListening: false, browserPorts: [], liveColumns: ["term"])
        XCTAssertEqual(
            book.probeFinished(port: 8000, isListening: true, browserPorts: [], liveColumns: ["term"]),
            .proposed
        )
    }

    func testUnknownProbeIsDropped() {
        var book = Book()
        XCTAssertEqual(book.probeFinished(port: 1234, isListening: true, browserPorts: [], liveColumns: ["term"]), .dropped)
        XCTAssertTrue(book.proposals.isEmpty)
    }

    // MARK: - Browser columns

    func testPortAlreadyShownInABrowserColumnIsNotProposed() {
        var book = Book()
        XCTAssertFalse(book.noteDetected(url(5173), in: "term", browserPorts: [5173]))
        // A browser column opened on the port while probing.
        XCTAssertTrue(book.noteDetected(url(3000), in: "term", browserPorts: []))
        XCTAssertEqual(
            book.probeFinished(port: 3000, isListening: true, browserPorts: [3000], liveColumns: ["term"]),
            .dropped
        )
        XCTAssertTrue(book.proposals.isEmpty)
    }

    func testBrowserColumnOnThePortPrunesTheProposal() {
        var book = Book()
        propose(&book, url(5173))
        XCTAssertTrue(book.liveProposals(browserPorts: [5173], liveColumns: ["term"]).isEmpty)
        XCTAssertTrue(book.prune(browserPorts: [5173], liveColumns: ["term"]))
        XCTAssertNil(book.proposal(for: "term"))
    }

    // MARK: - User actions

    func testDismissedPortIsNeverProposedAgain() {
        var book = Book()
        propose(&book, url(5173))
        book.dismiss(port: 5173)
        XCTAssertNil(book.proposal(for: "term"))
        XCTAssertFalse(book.noteDetected(url(5173), in: "term", browserPorts: []))
        XCTAssertFalse(book.noteDetected(url(5173), in: "other", browserPorts: []))
    }

    func testOpenedPortCanBeProposedAgainAfterARestart() {
        var book = Book()
        propose(&book, url(5173))
        book.markOpened(port: 5173)
        XCTAssertNil(book.proposal(for: "term"))
        XCTAssertTrue(book.noteDetected(url(5173), in: "term", browserPorts: []))
    }

    // MARK: - Liveness + columns

    func testStoppedServerIsPrunedOthersStay() {
        var book = Book()
        propose(&book, url(3000))
        propose(&book, url(5173))
        XCTAssertTrue(book.prune(stoppedPorts: [3000], browserPorts: [], liveColumns: ["term"]))
        XCTAssertEqual(book.proposals.map(\.url.port), [5173])
        XCTAssertFalse(book.prune(stoppedPorts: [], browserPorts: [], liveColumns: ["term"]))
    }

    func testClosedTerminalDropsItsProposalsAndPendingProbes() {
        var book = Book()
        propose(&book, url(3000), in: "gone")
        XCTAssertTrue(book.noteDetected(url(4000), in: "gone", browserPorts: []))
        XCTAssertEqual(book.probeFinished(port: 4000, isListening: true, browserPorts: [], liveColumns: ["term"]), .dropped)
        XCTAssertTrue(book.liveProposals(browserPorts: [], liveColumns: ["term"]).isEmpty)
        XCTAssertTrue(book.prune(browserPorts: [], liveColumns: ["term"]))
        XCTAssertTrue(book.proposals.isEmpty)
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
        // Dismissing the chip reveals the column's previous proposal.
        book.dismiss(port: 6006)
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

    // MARK: - Probe

    func testProbeSeesAListeningLoopbackSocketAndItsClosing() throws {
        let (fd, port) = try listen(family: AF_INET)
        XCTAssertTrue(LocalPortProbe.isListening(url(port, host: "127.0.0.1")))
        XCTAssertTrue(LocalPortProbe.isListening(url(port, host: "localhost")))
        close(fd)
        XCTAssertFalse(LocalPortProbe.isListening(url(port, host: "127.0.0.1")))
        XCTAssertFalse(LocalPortProbe.isListening(url(port, host: "localhost")))
    }

    func testProbeTriesIPv6ForLocalhost() throws {
        let (fd, port) = try listen(family: AF_INET6)
        defer { close(fd) }
        XCTAssertTrue(LocalPortProbe.isListening(url(port, host: "[::1]")))
        XCTAssertTrue(LocalPortProbe.isListening(url(port, host: "localhost")))
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
