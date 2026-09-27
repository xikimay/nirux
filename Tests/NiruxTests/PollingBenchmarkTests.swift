import AppKit
import XCTest
@testable import Nirux

/// Opt-in measurement of the background refresh cost: git and gh launches
/// and process-table scans per minute for a realistic workspace layout.
/// Skipped unless NIRUX_POLLING_BENCH=1, so the regular suite never shells
/// out to GitHub. The shell view's heartbeat saves state, so the benchmark
/// refuses to run without an explicit NIRUX_STATE_DIR.
///
///     NIRUX_POLLING_BENCH=1 NIRUX_STATE_DIR=/tmp/nirux-bench \
///     NIRUX_POLLING_BENCH_ACTIVE=/repo/a:/repo/b \
///     NIRUX_POLLING_BENCH_ARCHIVED=/repo/c \
///     swift test --filter PollingBenchmarkTests
///
/// Optional: NIRUX_POLLING_BENCH_SECONDS (measured window, default 120),
/// NIRUX_POLLING_BENCH_WARMUP (default 30), NIRUX_POLLING_BENCH_EDIT_EVERY
/// (seconds between simulated agent edits in the first three active
/// repositories, default 0 = idle) and NIRUX_POLLING_BENCH_TITLE_HZ (title
/// updates per second per active workspace, default 0).
@MainActor
final class PollingBenchmarkTests: XCTestCase {
    @MainActor
    private final class TickCounter {
        var edits = 0
        var titles = 0
    }

    private struct Configuration {
        let activePaths: [String]
        let archivedPaths: [String]
        let seconds: TimeInterval
        let warmup: TimeInterval
        let editEvery: TimeInterval
        let titleHz: Double
    }

    func testPollingCostPerMinute() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["NIRUX_POLLING_BENCH"] == "1" else {
            throw XCTSkip("Set NIRUX_POLLING_BENCH=1 to run the polling benchmark")
        }
        let stateDirectory = try XCTUnwrap(
            environment["NIRUX_STATE_DIR"].flatMap { $0.isEmpty ? nil : $0 },
            "NIRUX_STATE_DIR must point at a throwaway directory"
        )
        let configuration = Self.configuration(from: environment)
        XCTAssertFalse(configuration.activePaths.isEmpty, "NIRUX_POLLING_BENCH_ACTIVE is empty")

        let shell = NiruxShellView(frame: NSRect(x: 0, y: 0, width: 1600, height: 1000))
        let placeholderWorkspaces = shell.workspaces
        for path in configuration.activePaths + configuration.archivedPaths {
            shell.addWorkspace(title: (path as NSString).lastPathComponent, cwd: path)
        }
        for workspace in placeholderWorkspaces {
            _ = shell.workspaceStore.removeWorkspace(workspace)
            workspace.containerView.removeFromSuperview()
        }
        let archived = Set(configuration.archivedPaths)
        for (index, workspace) in shell.workspaces.enumerated() where archived.contains(workspace.cwd) {
            _ = shell.workspaceStore.setWorkspaceInactive(at: index, true)
        }
        shell.switchToWorkspace(0)

        let activeWorkspaces = shell.workspaces.filter { !$0.isInactive }
        let ticks = TickCounter()
        var timers: [Timer] = []
        if configuration.editEvery > 0 {
            let editedPaths = Array(configuration.activePaths.prefix(3))
            timers.append(Timer.scheduledTimer(withTimeInterval: configuration.editEvery, repeats: true) { _ in
                MainActor.assumeIsolated {
                    ticks.edits += 1
                    for path in editedPaths {
                        let file = URL(fileURLWithPath: path).appendingPathComponent("nirux-bench-edit.txt")
                        try? "edit \(ticks.edits)\n".write(to: file, atomically: true, encoding: .utf8)
                    }
                }
            })
        }
        if configuration.titleHz > 0 {
            timers.append(Timer.scheduledTimer(withTimeInterval: 1 / configuration.titleHz, repeats: true) { _ in
                MainActor.assumeIsolated {
                    ticks.titles += 1
                    for workspace in activeWorkspaces {
                        guard let column = workspace.columns[safe: workspace.focusedIndex] else { continue }
                        column.terminalTitle = "✳ Working \(ticks.titles % 10)"
                        column.onTitleChanged?()
                    }
                }
            })
        }

        let start = PollingDiagnostics.counts
        RunLoop.main.run(until: Date().addingTimeInterval(configuration.warmup))
        let afterWarmup = PollingDiagnostics.counts
        RunLoop.main.run(until: Date().addingTimeInterval(configuration.seconds))
        let end = PollingDiagnostics.counts
        timers.forEach { $0.invalidate() }
        shell.stopHeartbeat()

        let warmupCounts = afterWarmup - start
        let steadyCounts = end - afterWarmup
        let perMinute = 60 / configuration.seconds
        let report: [String: Any] = [
            "activeWorkspaces": configuration.activePaths.count,
            "archivedWorkspaces": configuration.archivedPaths.count,
            "warmupSeconds": configuration.warmup,
            "measuredSeconds": configuration.seconds,
            "editEverySeconds": configuration.editEvery,
            "titleHz": configuration.titleHz,
            "warmup": Self.dictionary(warmupCounts, scale: 1),
            "perMinute": Self.dictionary(steadyCounts, scale: perMinute)
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let reportURL = URL(fileURLWithPath: stateDirectory).appendingPathComponent("polling-bench.json")
        try data.write(to: reportURL)
        print("POLLING_BENCH \(String(bytes: data, encoding: .utf8) ?? "")")
    }

    private static func configuration(from environment: [String: String]) -> Configuration {
        func paths(_ key: String) -> [String] {
            (environment[key] ?? "").split(separator: ":").map(String.init).filter { !$0.isEmpty }
        }
        func number(_ key: String, default value: Double) -> Double {
            environment[key].flatMap(Double.init) ?? value
        }
        return Configuration(
            activePaths: paths("NIRUX_POLLING_BENCH_ACTIVE"),
            archivedPaths: paths("NIRUX_POLLING_BENCH_ARCHIVED"),
            seconds: number("NIRUX_POLLING_BENCH_SECONDS", default: 120),
            warmup: number("NIRUX_POLLING_BENCH_WARMUP", default: 30),
            editEvery: number("NIRUX_POLLING_BENCH_EDIT_EVERY", default: 0),
            titleHz: number("NIRUX_POLLING_BENCH_TITLE_HZ", default: 0)
        )
    }

    private static func dictionary(_ counts: PollingDiagnostics.Counts, scale: Double) -> [String: Double] {
        [
            "git": (Double(counts.gitLaunches) * scale).rounded(),
            "gh": (Double(counts.ghLaunches) * scale).rounded(),
            "other": (Double(counts.otherLaunches) * scale).rounded(),
            "processTableScans": (Double(counts.processTableScans) * scale).rounded()
        ]
    }
}
