import AppKit
import XCTest
@testable import Nirux

/// Opt-in measurement of a restore with many agent columns, each mode in
/// turn: processes started, CPU they burn, how long the main thread stalls.
/// No agent runs: each launch is a stand-in that burns CPU for a moment,
/// as an agent does while it starts, then sleeps. The columns' login
/// shells are real, so they read the user's startup files. Skipped unless
/// NIRUX_LAZY_RESTORE_BENCH=1.
///
///     NIRUX_LAZY_RESTORE_BENCH=1 swift test --filter LazyRestoreBenchmarkTests
///
/// Optional: NIRUX_LAZY_RESTORE_BENCH_WORKSPACES (default 10, two agents
/// each) and NIRUX_LAZY_RESTORE_BENCH_SECONDS (window measured after the
/// restore, default 8).
@MainActor
final class LazyRestoreBenchmarkTests: XCTestCase {
    private struct Measure {
        let restore: TimeInterval
        let usableAfter: TimeInterval
        let worstStall: TimeInterval
        let processes: Int
        let cpuSeconds: Double
    }

    func testRestoreCostPerMode() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["NIRUX_LAZY_RESTORE_BENCH"] == "1" else {
            throw XCTSkip("Set NIRUX_LAZY_RESTORE_BENCH=1 to run the lazy restore benchmark")
        }
        let workspaceCount = environment["NIRUX_LAZY_RESTORE_BENCH_WORKSPACES"].flatMap(Int.init) ?? 10
        let seconds = environment["NIRUX_LAZY_RESTORE_BENCH_SECONDS"].flatMap(TimeInterval.init) ?? 8
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-restore-bench-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("state"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let agent = root.appendingPathComponent("fake-agent").path
        try Data("""
            #!/bin/zsh -f
            typeset -F SECONDS
            while (( SECONDS < 1.5 )); do :; done
            exec sleep 600

            """.utf8).write(to: URL(fileURLWithPath: agent))
        chmod(agent, 0o755)

        var report: [String] = []
        for mode in [AgentResumeOnLaunch.allAtOnce, .lazily] {
            let measure = try measureRestore(
                mode: mode, workspaceCount: workspaceCount, seconds: seconds, root: root.path, agent: agent
            )
            report.append(String(
                format: "%@: restore %.0f ms, usable after %.0f ms, worst stall %.0f ms, %d processes, %.1f CPU s",
                mode.rawValue, measure.restore * 1000, measure.usableAfter * 1000, measure.worstStall * 1000,
                measure.processes, measure.cpuSeconds
            ))
        }
        print("[LazyRestoreBench] \(workspaceCount) workspaces × 2 agents, \(Int(seconds)) s window\n"
            + report.map { "[LazyRestoreBench] " + $0 }.joined(separator: "\n"))
    }

    private func measureRestore(
        mode: AgentResumeOnLaunch, workspaceCount: Int, seconds: TimeInterval, root: String, agent: String
    ) throws -> Measure {
        let previous = ProcessInfo.processInfo.environment["NIRUX_STATE_DIR"]
        setenv("NIRUX_STATE_DIR", root + "/state", 1)
        defer {
            if let previous { setenv("NIRUX_STATE_DIR", previous, 1) } else { unsetenv("NIRUX_STATE_DIR") }
        }
        var state = PersistedState(
            workspaces: (0..<workspaceCount).map { index in
                PersistedWorkspace(id: "ws\(index)", title: "ws\(index)", cwd: root, columns: (0..<2).map { _ in
                    PersistedColumn(
                        widthPreset: 0.5, cwd: root, columnType: .claudeCode, webViewURL: nil,
                        claudeLaunchMode: nil, codexLaunchMode: nil,
                        claudeSessionID: UUID().uuidString, agentUUID: UUID().uuidString
                    )
                }, focusedColumnIndex: 0)
            },
            activeWorkspaceIndex: 0
        )
        var settings = PersistedSettings()
        settings.agentResumeOnLaunch = mode
        state.settings = settings
        XCTAssertTrue(Persistence.save(state))

        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        var measure: Measure?
        try autoreleasepool {
            let shell = NiruxShellView(frame: NSRect(x: 0, y: 0, width: 1400, height: 900))
            shell.stopHeartbeat()
            shell.sideEffects.startRestoredAgent = { column, _ in column.startShell(command: "command \(agent)") }
            window.contentView = shell
            window.orderFront(nil)

            let start = Date()
            shell.restoreState()
            let restore = Date().timeIntervalSince(start)
            let stalls = watchMainThread(for: seconds)
            measure = Measure(
                restore: restore,
                usableAfter: max(restore, stalls.lastStallAt.map { $0.timeIntervalSince(start) } ?? 0),
                worstStall: stalls.worst,
                processes: Self.descendants().count,
                cpuSeconds: Self.descendants().reduce(0) { $0 + Self.cpuSeconds(of: $1) }
            )
            window.contentView = nil
            window.close()
            XCTAssertTrue(try XCTUnwrap(measure).processes > 0, "no shell started")
        }
        let leftovers = Self.descendants()
        for pid in leftovers { kill(pid, SIGKILL) }
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        // The columns that reaped their shells are gone.
        for pid in leftovers { waitpid(pid, nil, WNOHANG) }
        return try XCTUnwrap(measure)
    }

    /// Main-thread lateness over `seconds`, ticking every 10 ms: the worst
    /// delay, and when the last one over 50 ms ended.
    private func watchMainThread(for seconds: TimeInterval) -> (worst: TimeInterval, lastStallAt: Date?) {
        var worst: TimeInterval = 0
        var lastStallAt: Date?
        var last = Date()
        let deadline = last.addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            let now = Date()
            let late = now.timeIntervalSince(last) - 0.01
            worst = max(worst, late)
            if late > 0.05 { lastStallAt = now }
            last = now
        }
        return (worst, lastStallAt)
    }

    /// Every live process under this one: a zombie is no longer described.
    private static func descendants(of parent: pid_t = getpid()) -> [pid_t] {
        var pids = [pid_t](repeating: 0, count: 1024)
        let count = proc_listchildpids(parent, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        let children = pids.prefix(Int(max(count, 0))).filter { pid in
            var info = proc_bsdinfo()
            return pid > 0 && proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0
        }
        return children + children.flatMap { descendants(of: $0) }
    }

    private static func cpuSeconds(of pid: pid_t) -> Double {
        var usage = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
            }
        }
        guard result == 0 else { return 0 }
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let ticks = Double(usage.ri_user_time + usage.ri_system_time)
        return ticks * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }
}
