import AppKit
import XCTest
@testable import Nirux

@MainActor
final class CrashNoticeStatusBarTests: XCTestCase {
    private func notice(count: Int = 1) throws -> CrashNotice {
        let report = try XCTUnwrap(CrashReportParser.report(from: CrashReportFixtures.report()))
        return CrashNotice(
            report: report,
            reportURL: URL(fileURLWithPath: "/tmp/Nirux-2026-09-27-111448.ips"),
            date: Date(timeIntervalSince1970: 1_790_500_488),
            reportCount: count
        )
    }

    private func makeBar() -> StatusBarView {
        // performClick sends the action through NSApp.
        _ = NSApplication.shared
        let bar = StatusBarView(frame: NSRect(x: 0, y: 0, width: 1200, height: StatusBarView.height))
        bar.layoutSubtreeIfNeeded()
        return bar
    }

    /// A shown button: the queue's ✕ hides while no queue ended.
    private func button(_ title: String, in bar: StatusBarView) -> NSButton? {
        bar.subviews.compactMap { $0 as? NSButton }.first { $0.title == title && !$0.isHidden }
    }

    private func visibleButtonTitles(in bar: StatusBarView) -> [String] {
        bar.subviews.compactMap { $0 as? NSButton }.filter { !$0.isHidden }.map(\.title).sorted()
    }

    private func labelText(in bar: StatusBarView) -> String? {
        bar.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue.hasPrefix("●") }?.stringValue
    }

    func testCrashTextNamesTheCrash() throws {
        XCTAssertEqual(
            StatusBarView.crashText(for: try notice()),
            "● Nirux crashed · EXC_BREAKPOINT in NiruxShellView.inspectForPanel"
        )
        XCTAssertEqual(
            StatusBarView.crashText(for: try notice(count: 3)),
            "● Nirux crashed 3× · EXC_BREAKPOINT in NiruxShellView.inspectForPanel"
        )
    }

    func testCrashNoticeOutranksAnUpdateUntilDismissed() throws {
        let bar = makeBar()
        var contentChanges: [Bool] = []
        bar.onContentChange = { [weak bar] in contentChanges.append(bar?.hasContent ?? false) }
        XCTAssertFalse(bar.hasContent)

        bar.showCrash(try notice())
        bar.showUpdate(version: "nightly-2026.09.28")
        XCTAssertTrue(bar.hasContent)
        XCTAssertEqual(labelText(in: bar), "● Nirux crashed · EXC_BREAKPOINT in NiruxShellView.inspectForPanel")
        XCTAssertEqual(visibleButtonTitles(in: bar), ["Copy summary", "Open report", "✕"])
        XCTAssertEqual(contentChanges, [true], "the bar appears once")

        try XCTUnwrap(button("✕", in: bar)).performClick(nil)
        XCTAssertNil(bar.crashNotice)
        XCTAssertEqual(labelText(in: bar), "● Update available · nightly-2026.09.28")
        XCTAssertEqual(visibleButtonTitles(in: bar), ["Install ↗", "✕"])
        XCTAssertEqual(contentChanges, [true], "still showing a notice")

        try XCTUnwrap(button("✕", in: bar)).performClick(nil)
        XCTAssertFalse(bar.hasContent)
        XCTAssertEqual(visibleButtonTitles(in: bar), [])
        XCTAssertEqual(contentChanges, [true, false], "the bar can hide")
    }

    func testCrashButtonsReportTheirAction() throws {
        let bar = makeBar()
        var actions: [StatusBarView.CrashAction] = []
        bar.onCrashAction = { actions.append($0) }
        bar.showCrash(try notice())

        try XCTUnwrap(button("Copy summary", in: bar)).performClick(nil)
        XCTAssertNotNil(button("Copied ✓", in: bar), "confirms the copy")
        try XCTUnwrap(button("Open report", in: bar)).performClick(nil)
        XCTAssertEqual(actions, [.copySummary, .openReport])
    }

    func testNoticeIsNotTruncatedAndButtonsFollowIt() throws {
        let bar = makeBar()
        bar.showCrash(try notice())
        bar.layoutSubtreeIfNeeded()
        let label = try XCTUnwrap(bar.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue.hasPrefix("●") })
        XCTAssertGreaterThanOrEqual(label.frame.width, ceil(label.attributedStringValue.size().width), "not truncated")
        let copy = try XCTUnwrap(button("Copy summary", in: bar))
        let open = try XCTUnwrap(button("Open report", in: bar))
        let dismiss = try XCTUnwrap(button("✕", in: bar))
        XCTAssertLessThan(label.frame.maxX, copy.frame.minX)
        XCTAssertLessThan(copy.frame.maxX, open.frame.minX)
        XCTAssertLessThan(open.frame.maxX, dismiss.frame.minX)
        XCTAssertEqual(
            bar.hitTest(NSPoint(x: dismiss.frame.midX, y: dismiss.frame.midY)), dismiss
        )
    }

    func testCopiedFlashDoesNotMoveTheButtons() throws {
        let bar = makeBar()
        bar.showCrash(try notice())
        bar.layoutSubtreeIfNeeded()
        let open = try XCTUnwrap(button("Open report", in: bar))
        let dismiss = try XCTUnwrap(button("✕", in: bar))
        let before = [open.frame, dismiss.frame]

        try XCTUnwrap(button("Copy summary", in: bar)).performClick(nil)
        bar.needsLayout = true
        bar.layoutSubtreeIfNeeded()
        XCTAssertNotNil(button("Copied ✓", in: bar))
        XCTAssertEqual([open.frame, dismiss.frame], before)
    }

    func testNarrowLayoutKeepsTheLeftHalf() throws {
        let bar = makeBar()
        bar.setFrameSize(NSSize(width: 720, height: StatusBarView.height))
        bar.showUpdate(version: "nightly-2026.09.28")
        bar.layoutSubtreeIfNeeded()
        let label = try XCTUnwrap(bar.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue.hasPrefix("●") })
        XCTAssertGreaterThanOrEqual(label.frame.width, min(ceil(label.attributedStringValue.size().width), 720 / 2 - 16))
        let install = try XCTUnwrap(button("Install ↗", in: bar))
        XCTAssertEqual(bar.hitTest(NSPoint(x: install.frame.midX, y: install.frame.midY)), install)
    }

    func testButtonsTakeTheirClicksAtEveryWidth() throws {
        let bar = makeBar()
        bar.showCrash(try notice())
        for width in stride(from: CGFloat(600), through: 1400, by: 25) {
            bar.setFrameSize(NSSize(width: width, height: StatusBarView.height))
            bar.layoutSubtreeIfNeeded()
            for title in ["Copy summary", "Open report", "✕"] {
                let target = try XCTUnwrap(button(title, in: bar))
                XCTAssertEqual(
                    bar.hitTest(NSPoint(x: target.frame.midX, y: target.frame.midY)), target, "\(title) at \(width)"
                )
            }
        }
    }

    func testCopySummaryWritesThePasteboard() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("nirux-crash-tests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let notice = try notice()
        CrashNoticeActions.copySummary(of: notice, to: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), notice.summary)
        XCTAssertTrue(notice.summary.hasPrefix("Nirux crashed: EXC_BREAKPOINT (SIGTRAP)\n"))
    }
}
