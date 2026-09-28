import XCTest
@testable import Nirux

final class CrashReportParserTests: XCTestCase {
    private typealias Fixtures = CrashReportFixtures

    private func parsed(_ data: Data = Fixtures.report()) throws -> CrashReport {
        try XCTUnwrap(CrashReportParser.report(from: data))
    }

    // MARK: - Header

    func testParsesHeader() throws {
        let header = try XCTUnwrap(CrashReportParser.header(from: Fixtures.report()))
        XCTAssertEqual(header.bugType, "309")
        XCTAssertTrue(header.isCrash)
        XCTAssertEqual(header.bundleID, "com.xikimay.nirux")
        XCTAssertEqual(header.appName, "Nirux")
        XCTAssertEqual(header.appVersion, "nightly-2026.09.27")
        XCTAssertEqual(header.buildVersion, "202609270901")
        XCTAssertEqual(header.osVersion, "macOS 26.5.2 (25F84)")
        XCTAssertEqual(header.incidentID, Fixtures.incidentID)
        // 2026-09-27 09:14:48 UTC
        XCTAssertEqual(header.timestamp, Date(timeIntervalSince1970: 1_790_500_488))
    }

    func testHeaderOnlyNeedsTheFirstLine() throws {
        let data = Data((Fixtures.header() + "\n{ \"truncated").utf8)
        XCTAssertEqual(CrashReportParser.header(from: data)?.incidentID, Fixtures.incidentID)
        XCTAssertEqual(CrashReportParser.header(from: Data(Fixtures.header().utf8))?.incidentID, Fixtures.incidentID)
    }

    func testUnreadableHeaderIsNoReport() {
        for text in ["", "\n{}", "not json\n{}", "[1, 2]\n{}", "{\"app_name\": \"Nirux\"", "\u{FF}\u{FE}\n{}"] {
            XCTAssertNil(CrashReportParser.header(from: Data(text.utf8)), text)
            XCTAssertNil(CrashReportParser.report(from: Data(text.utf8)), text)
        }
    }

    func testOtherBugTypesAreNotCrashes() throws {
        let hang = try XCTUnwrap(CrashReportParser.header(from: Data(Fixtures.header(bugType: "288").utf8)))
        XCTAssertFalse(hang.isCrash)
        let unknown = try XCTUnwrap(CrashReportParser.header(from: Data(Fixtures.header(bugType: nil).utf8)))
        XCTAssertTrue(unknown.isCrash)
    }

    func testTimestampFormats() {
        let whole = Date(timeIntervalSince1970: 1_790_500_488)
        XCTAssertEqual(CrashReportParser.date(from: "2026-09-27 11:14:48 +0200"), whole)
        XCTAssertEqual(CrashReportParser.date(from: "2026-09-27 11:14:48.00 +0200"), whole)
        XCTAssertEqual(CrashReportParser.date(from: "2026-09-27 09:14:48.0000 +0000"), whole)
        let fraction = try? XCTUnwrap(CrashReportParser.date(from: "2026-09-27 11:14:48.25 +0200"))
        XCTAssertEqual(fraction?.timeIntervalSince(whole) ?? 0, 0.25, accuracy: 0.0001)
        let invalid = [
            "", "yesterday", "2026-09-27T11:14:48Z", "2026-09-27 11:14:48.xx +0200", "2026-13-40 99:99:99 +0200",
            "2026-09-27 . +0200", "2026-09-27 .. +0200", "2026-09-27 .5 +0200", "2026-09-27 11:14:48. +0200",
            "2026-09-27 11:14:48.1e3 +0200", "2026-09-27  11:14:48 +0200", " . ", "  "
        ]
        for text in invalid {
            XCTAssertNil(CrashReportParser.date(from: text), text)
        }
    }

    // MARK: - Body

    func testParsesBody() throws {
        let report = try parsed()
        XCTAssertTrue(report.hasBody)
        XCTAssertEqual(report.processName, "Nirux")
        XCTAssertEqual(report.exceptionType, "EXC_BREAKPOINT")
        XCTAssertEqual(report.signal, "SIGTRAP")
        XCTAssertNil(report.exceptionSubtype)
        XCTAssertEqual(report.termination, "Trace/BPT trap: 5")
        XCTAssertEqual(report.crashTime, "2026-09-27 11:14:19.6973 +0200")
        XCTAssertEqual(report.faultingThread, 2)
        XCTAssertEqual(report.faultingQueue, "NSOperationQueue 0x600000000000 (QOS: UNSPECIFIED)")
        XCTAssertEqual(report.frames.count, 20)
        XCTAssertEqual(report.frames[0], CrashReport.Frame(
            image: "libdispatch.dylib", symbol: "_dispatch_assert_queue_fail", symbolOffset: 120, imageOffset: 226_556
        ))
        XCTAssertEqual(report.frames[19], CrashReport.Frame(
            image: "libsystem_pthread.dylib", symbol: nil, symbolOffset: nil, imageOffset: 11_908
        ))
        XCTAssertEqual(report.appFrame?.symbol, "closure #1 in NiruxShellView.inspectForPanel(_:panel:queue:)")
        XCTAssertEqual(report.exceptionBacktrace, [])
        XCTAssertEqual(report.messages, [])
    }

    func testTruncatedBodyKeepsTheHeader() throws {
        let body = Fixtures.body
        let report = try parsed(Fixtures.report(body: String(body.prefix(body.count / 2))))
        XCTAssertFalse(report.hasBody)
        XCTAssertEqual(report.header.incidentID, Fixtures.incidentID)
        XCTAssertEqual(report.frames, [])

        let headerOnly = try parsed(Data(Fixtures.header().utf8))
        XCTAssertFalse(headerOnly.hasBody)
    }

    func testMissingFieldsReadAsAbsent() throws {
        let report = try parsed(Data("{}\n{}".utf8))
        XCTAssertTrue(report.hasBody)
        XCTAssertNil(report.header.incidentID)
        XCTAssertNil(report.header.timestamp)
        XCTAssertNil(report.processName)
        XCTAssertNil(report.exceptionType)
        XCTAssertNil(report.faultingThread)
        XCTAssertEqual(report.frames, [])
        XCTAssertNil(report.appFrame)
    }

    func testFieldsOfTheWrongTypeReadAsAbsent() throws {
        let body = """
        {
          "procName" : 42,
          "exception" : "EXC_CRASH",
          "termination" : ["SIGABRT"],
          "faultingThread" : true,
          "threads" : [{"triggered": true, "queue": 7, "frames": [
            "not a frame",
            {"imageIndex": 9, "symbol": "outOfRangeImage", "symbolLocation": "4"},
            {"imageIndex": -1, "imageOffset": 16},
            {"imageIndex": 0, "symbol": ""}
          ]}],
          "usedImages" : [{"name": ["Nirux"]}],
          "asi" : ["not", "a", "map"],
          "lastExceptionBacktrace" : {}
        }
        """
        let report = try parsed(Fixtures.report(body: body))
        XCTAssertTrue(report.hasBody)
        XCTAssertEqual(report.processName, "Nirux", "falls back to the header's app name")
        XCTAssertNil(report.exceptionType)
        XCTAssertNil(report.termination)
        XCTAssertEqual(report.faultingThread, 0, "a Bool isn't an index: the triggered thread is")
        XCTAssertNil(report.faultingQueue)
        XCTAssertEqual(report.frames, [
            CrashReport.Frame(image: nil, symbol: "outOfRangeImage", symbolOffset: nil, imageOffset: nil),
            CrashReport.Frame(image: nil, symbol: nil, symbolOffset: nil, imageOffset: 16),
            CrashReport.Frame(image: nil, symbol: nil, symbolOffset: nil, imageOffset: nil)
        ])
        XCTAssertEqual(report.messages, [])
        XCTAssertEqual(report.exceptionBacktrace, [])
    }

    func testFaultingThreadOutOfRangeFallsBackToTheTriggeredThread() throws {
        let body = """
        {"faultingThread": 9, "threads": [{"frames": []}, {"triggered": true, "queue": "q", "frames": [{"symbol": "f"}]}]}
        """
        let report = try parsed(Fixtures.report(body: body))
        XCTAssertEqual(report.faultingThread, 1)
        XCTAssertEqual(report.faultingQueue, "q")
        XCTAssertEqual(report.frames.map(\.symbol), ["f"])
    }

    func testTellsTheHookReceiverFromTheApp() throws {
        let app = try parsed()
        XCTAssertEqual(app.processRole, "Foreground")
        XCTAssertEqual(app.parentProcess, "launchd")
        XCTAssertFalse(app.isCommandLineRun)
        let cases: [(role: String, parent: String, commandLine: Bool)] = [
            ("Unspecified", "node", true),
            ("Unspecified", "Exited process", true),
            ("Default", "zsh", true),
            ("Non UI", "claude", true),
            ("Background", "launchd", false),
            ("Background", "zsh", false),
            ("Unspecified", "launchd", false)
        ]
        for (role, parent, commandLine) in cases {
            let report = try parsed(Fixtures.report(body: Fixtures.body(procRole: role, parentProc: parent)))
            XCTAssertEqual(report.isCommandLineRun, commandLine, "\(role) under \(parent)")
        }
        XCTAssertFalse(try parsed(Data(Fixtures.header().utf8)).isCommandLineRun, "unknown counts as the app")
    }

    func testFaultingThreadOutOfRange() throws {
        let report = try parsed(Fixtures.report(body: #"{"faultingThread": 5, "threads": [{"frames": []}]}"#))
        XCTAssertEqual(report.faultingThread, 5)
        XCTAssertEqual(report.frames, [])
    }

    func testReadsMessagesAndExceptionBacktrace() throws {
        let body = """
        {
          "procName" : "Nirux",
          "exception" : {"type": "EXC_CRASH", "signal": "SIGABRT"},
          "asi" : {"libswiftCore.dylib": ["Fatal error: Index out of range"], "AppKit": "*** reason"},
          "lastExceptionBacktrace" : [{"imageIndex": 0, "symbol": "NiruxApp.menuAction(_:)", "symbolLocation": 12}],
          "usedImages" : [{"name": "Nirux"}]
        }
        """
        let report = try parsed(Fixtures.report(body: body))
        XCTAssertEqual(report.messages, ["*** reason", "Fatal error: Index out of range"])
        XCTAssertEqual(report.exceptionBacktrace, [
            CrashReport.Frame(image: "Nirux", symbol: "NiruxApp.menuAction(_:)", symbolOffset: 12, imageOffset: nil)
        ])
    }

    func testHeadlinePrefersWhereTheExceptionWasThrown() throws {
        var report = try parsed()
        report.exceptionType = "EXC_CRASH"
        report.exceptionBacktrace = [
            CrashReport.Frame(image: "CoreFoundation", symbol: "__exceptionPreprocess", symbolOffset: 1, imageOffset: nil),
            CrashReport.Frame(image: "Nirux", symbol: "NiruxApp.menuAction(_:)", symbolOffset: 12, imageOffset: nil)
        ]
        XCTAssertEqual(CrashReportSummary.headline(for: report), "EXC_CRASH in NiruxApp.menuAction")
    }

    // MARK: - Summary

    func testHeadlineNamesTheAppFrame() throws {
        XCTAssertEqual(
            CrashReportSummary.headline(for: try parsed()),
            "EXC_BREAKPOINT in NiruxShellView.inspectForPanel"
        )
        XCTAssertEqual(CrashReportSummary.headline(for: try parsed(Data("{}\n{}".utf8))), "no details in the report")
        let signalOnly = try parsed(Fixtures.report(body: #"{"exception": {"signal": "SIGSEGV"}}"#))
        XCTAssertEqual(CrashReportSummary.headline(for: signalOnly), "SIGSEGV")
    }

    func testShortSymbol() {
        let cases = [
            "closure #1 in NiruxShellView.inspectForPanel(_:panel:queue:)": "NiruxShellView.inspectForPanel",
            "partial apply for implicit closure #2 in closure #1 in WorkspaceState.refresh()": "WorkspaceState.refresh",
            "specialized Array.subscript.getter": "Array.subscript.getter",
            "@objc NiruxApp.menuAction(_:)": "NiruxApp.menuAction",
            "-[NSView layout]": "-[NSView layout]",
            "-[NSView(NSConstraintBasedLayout) layout]": "-[NSView(NSConstraintBasedLayout) layout]",
            "static NiruxApp.main()": "NiruxApp.main",
            "(extension in Nirux):NSView.pin(to:)": "NSView.pin",
            "Box<(Int, Int)>.value.getter": "Box<(Int, Int)>.value.getter",
            "closure #1 (Int) -> () in Mission<(A) -> B>.run()": "Mission<(A) -> B>.run",
            "(": "("
        ]
        for (symbol, expected) in cases {
            XCTAssertEqual(CrashReportSummary.shortSymbol(symbol), expected, symbol)
        }
    }

    func testSummaryIsReadable() throws {
        let text = CrashReportSummary.text(for: try parsed(), reportPath: "~/Library/Logs/DiagnosticReports/Nirux-1.ips")
        let lines = text.components(separatedBy: "\n")
        XCTAssertEqual(Array(lines.prefix(7)), [
            "Nirux crashed: EXC_BREAKPOINT (SIGTRAP)",
            "Version: nightly-2026.09.27 (202609270901)",
            "Crashed at: 2026-09-27 11:14:19.6973 +0200",
            "OS: macOS 26.5.2 (25F84)",
            "Termination: Trace/BPT trap: 5",
            "",
            "Thread 2 crashed (queue: NSOperationQueue 0x600000000000 (QOS: UNSPECIFIED)):"
        ])
        XCTAssertEqual(lines[7], " 0  libdispatch.dylib           _dispatch_assert_queue_fail + 120")
        XCTAssertEqual(
            lines[12],
            " 5  Nirux                       closure #1 in NiruxShellView.inspectForPanel(_:panel:queue:) + 256"
        )
        XCTAssertEqual(lines[21], "14  libdispatch.dylib           _dispatch_client_callout + 16")
        XCTAssertEqual(lines[22], "    … 5 more frames in the report")
        XCTAssertEqual(Array(lines.suffix(2)), ["", "Report: ~/Library/Logs/DiagnosticReports/Nirux-1.ips"])
    }

    func testSummaryMentionsEarlierReportsAndTruncation() throws {
        let truncated = try parsed(Data(Fixtures.header().utf8))
        let text = CrashReportSummary.text(for: truncated, reportPath: "r.ips", otherReportCount: 2)
        XCTAssertEqual(text, """
        Nirux crashed: unknown exception
        Version: nightly-2026.09.27 (202609270901)
        OS: macOS 26.5.2 (25F84)

        The report is truncated or unreadable: only its header was parsed.

        2 earlier crash reports in the same folder.
        Report: r.ips
        """)
    }

    func testReportPathIsNeverCut() throws {
        let path = "/private/var/folders/" + String(repeating: "deep/", count: 60) + "Nirux-1.ips"
        let text = CrashReportSummary.text(for: try parsed(), reportPath: path)
        XCTAssertTrue(text.hasSuffix("\nReport: " + path))
    }

    func testSummaryIsBounded() throws {
        var report = try parsed()
        report.messages = (0..<10).map { "line \($0)\n\u{1B}[31m\u{2028}\u{2029}" + String(repeating: "x", count: 1000) }
        report.exceptionBacktrace = Array(repeating: CrashReport.Frame(
            image: String(repeating: "i", count: 100),
            symbol: String(repeating: "s", count: 5000), symbolOffset: 1, imageOffset: nil
        ), count: 40)
        let text = CrashReportSummary.text(for: report, reportPath: "~/Nirux-2.ips", otherReportCount: 1)
        XCTAssertLessThanOrEqual(text.count, CrashReportSummary.maxLength)
        XCTAssertTrue(text.hasSuffix("\n1 earlier crash report in the same folder.\nReport: ~/Nirux-2.ips"))
        let lines = text.components(separatedBy: "\n")
        XCTAssertEqual(lines.filter { $0.hasPrefix("Message: ") }.count, CrashReportSummary.maxMessages)
        XCTAssertTrue(lines.allSatisfy { $0.count <= CrashReportSummary.maxLineLength })
        let breaks = CharacterSet.controlCharacters.union(.newlines)
        XCTAssertFalse(text.unicodeScalars.contains { $0 != "\n" && breaks.contains($0) })
        XCTAssertTrue(lines.contains("…"), "marks the cut")
    }
}
