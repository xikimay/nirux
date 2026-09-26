import XCTest
@testable import Nirux

final class LocalServerURLScannerTests: XCTestCase {

    private func scan(_ text: String) -> [String] {
        var scanner = LocalServerURLScanner()
        return scanner.scan(Array(text.utf8)).map(\.urlString)
    }

    // MARK: - Real dev-server banners

    func testViteBannerWithBoldPort() {
        // Vite wraps the port in bold inside a cyan URL.
        let line = "  \u{1B}[32m➜\u{1B}[39m  \u{1B}[1mLocal\u{1B}[22m:   "
            + "\u{1B}[36mhttp://localhost:\u{1B}[1m5173\u{1B}[22m/\u{1B}[39m\r\n"
        XCTAssertEqual(scan(line), ["http://localhost:5173/"])
    }

    func testNextBannerWithoutPath() {
        XCTAssertEqual(scan("   - Local:        http://localhost:3000\n"), ["http://localhost:3000"])
    }

    func testDjangoLoopbackAddress() {
        XCTAssertEqual(
            scan("Starting development server at http://127.0.0.1:8000/\r\nQuit the server with CONTROL-C.\r\n"),
            ["http://127.0.0.1:8000/"]
        )
    }

    func testUnspecifiedBindAddressesBecomeLocalhost() {
        XCTAssertEqual(
            scan("Serving HTTP on :: port 8000 (http://[::]:8000/) ...\n"),
            ["http://localhost:8000/"]
        )
        XCTAssertEqual(scan("listening on http://0.0.0.0:4000\n"), ["http://localhost:4000"])
    }

    func testIPv6LoopbackIsKept() {
        XCTAssertEqual(scan("at http://[::1]:8080/\n"), ["http://[::1]:8080/"])
    }

    func testHTTPSAndCaseInsensitivity() {
        XCTAssertEqual(scan("HTTPS://LocalHost:8443/App\n"), ["https://localhost:8443/App"])
    }

    func testJupyterTokenPathIsKept() {
        let url = "http://127.0.0.1:8888/tree?token=0123456789abcdef0123456789abcdef"
        XCTAssertEqual(scan("    \(url)\n"), [url])
    }

    func testSeveralURLsInOneChunk() {
        XCTAssertEqual(
            scan("web http://localhost:5173/ api http://127.0.0.1:3000/graphql\n"),
            ["http://localhost:5173/", "http://127.0.0.1:3000/graphql"]
        )
    }

    // MARK: - Rejections

    func testNonLoopbackHostsAreIgnored() {
        XCTAssertEqual(scan("http://example.com:3000/\n"), [])
        XCTAssertEqual(scan("Network: http://192.168.1.20:5173/\n"), [])
        XCTAssertEqual(scan("http://localhost.evil.com:3000/\n"), [])
        XCTAssertEqual(scan("http://localhostx:3000/\n"), [])
        XCTAssertEqual(scan("http://127.0.0.10:3000/\n"), [])
    }

    func testPortIsRequiredAndValid() {
        XCTAssertEqual(scan("http://localhost/\n"), [])
        XCTAssertEqual(scan("http://localhost:/\n"), [])
        XCTAssertEqual(scan("http://localhost:0/\n"), [])
        XCTAssertEqual(scan("http://localhost:65536/\n"), [])
        XCTAssertEqual(scan("http://localhost:123456/\n"), [])
        XCTAssertEqual(scan("http://localhost:3000abc\n"), [])
    }

    func testOtherSchemesAreIgnored() {
        XCTAssertEqual(scan("file://localhost:3000/x ws://localhost:3000 xhttp:/localhost:3000\n"), [])
    }

    func testColonHeavyTextWithoutURLs() {
        XCTAssertEqual(scan("12:30:01 [vite] hmr update: /src/App.tsx, key: value :: a://b\n"), [])
    }

    // MARK: - Boundaries

    func testTrailingPunctuationIsTrimmed() {
        XCTAssertEqual(scan("Open http://localhost:3000/.\n"), ["http://localhost:3000/"])
        XCTAssertEqual(scan("(see http://localhost:3000/docs).\n"), ["http://localhost:3000/docs"])
        XCTAssertEqual(scan("at http://localhost:3000, then\n"), ["http://localhost:3000"])
    }

    func testNonSGREscapeEndsTheURL() {
        XCTAssertEqual(scan("http://localhost:3000\u{1B}[K\n"), ["http://localhost:3000"])
        // A cursor move means the next bytes belong elsewhere on screen.
        XCTAssertEqual(scan("http://localhost:3000/path\u{1B}[2;1Hmore\n"), ["http://localhost:3000/path"])
        XCTAssertEqual(scan("http://local\u{1B}[2Jhost:3000/\n"), [])
    }

    func testOSC8HyperlinkTarget() {
        let link = "\u{1B}]8;;http://localhost:3000/\u{1B}\\open\u{1B}]8;;\u{1B}\\\n"
        XCTAssertEqual(scan(link), ["http://localhost:3000/"])
    }

    func testOverlongPathFallsBackToServerRoot() {
        let path = "/" + String(repeating: "a", count: 450)
        XCTAssertEqual(scan("http://localhost:3000\(path) \n"), ["http://localhost:3000"])
    }

    // MARK: - Chunk splits

    func testURLSplitAtEveryByteBoundary() {
        let line = Array("x \u{1B}[36mhttp://localhost:\u{1B}[1m5173\u{1B}[22m/app?x=1\u{1B}[39m\r\n".utf8)
        for split in 0...line.count {
            var scanner = LocalServerURLScanner()
            let urls = scanner.scan(Array(line[..<split])) + scanner.scan(Array(line[split...]))
            XCTAssertEqual(urls.map(\.urlString), ["http://localhost:5173/app?x=1"], "split at \(split)")
        }
    }

    func testURLFedOneByteAtATime() {
        var scanner = LocalServerURLScanner()
        var urls: [LocalServerURL] = []
        for byte in "Local: https://127.0.0.1:8443/\n".utf8 {
            urls += scanner.scan([byte])
        }
        XCTAssertEqual(urls.map(\.urlString), ["https://127.0.0.1:8443/"])
    }

    func testURLAtChunkEndWaitsForItsTerminator() {
        var scanner = LocalServerURLScanner()
        // More port digits or path could still follow.
        XCTAssertEqual(scanner.scan(Array("Local: http://localhost:51".utf8)), [])
        XCTAssertEqual(scanner.scan(Array("73/\n".utf8)).map(\.urlString), ["http://localhost:5173/"])
    }

    func testOverlongCandidateAtChunkEndIsOfferedAsRoot() {
        var scanner = LocalServerURLScanner()
        let chunk = "http://localhost:3000/?q=" + String(repeating: "b", count: 600)
        XCTAssertEqual(scanner.scan(Array(chunk.utf8)).map(\.urlString), ["http://localhost:3000"])
        XCTAssertEqual(scanner.scan(Array("tail\n".utf8)), [])
    }

    // MARK: - Browser column ports

    func testLoopbackPortOfBrowserURL() {
        XCTAssertEqual(LocalServerURL.loopbackPort(of: "http://localhost:5173/foo"), 5173)
        XCTAssertEqual(LocalServerURL.loopbackPort(of: "http://127.0.0.1/"), 80)
        XCTAssertEqual(LocalServerURL.loopbackPort(of: "https://localhost/"), 443)
        XCTAssertEqual(LocalServerURL.loopbackPort(of: "http://[::1]:8080/"), 8080)
        XCTAssertEqual(LocalServerURL.loopbackPort(of: "http://0.0.0.0:4000"), 4000)
        XCTAssertNil(LocalServerURL.loopbackPort(of: "https://example.com:5173/"))
        XCTAssertNil(LocalServerURL.loopbackPort(of: "about:blank"))
        XCTAssertNil(LocalServerURL.loopbackPort(of: ""))
    }
}
