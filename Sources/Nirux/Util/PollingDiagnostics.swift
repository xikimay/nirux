import Foundation
import os

/// Process-wide counters for the background refresh paths: git and gh
/// launches (everything that goes through `BoundedProcess`) and full
/// process-table scans (`ProcessSnapshot`). Incrementing is a single
/// uncontended lock, cheap enough to stay on in release builds; the opt-in
/// polling benchmark reads them to report per-minute costs.
enum PollingDiagnostics {
    struct Counts: Equatable, Sendable {
        var gitLaunches = 0
        var ghLaunches = 0
        var otherLaunches = 0
        var processTableScans = 0

        static func - (lhs: Counts, rhs: Counts) -> Counts {
            Counts(
                gitLaunches: lhs.gitLaunches - rhs.gitLaunches,
                ghLaunches: lhs.ghLaunches - rhs.ghLaunches,
                otherLaunches: lhs.otherLaunches - rhs.otherLaunches,
                processTableScans: lhs.processTableScans - rhs.processTableScans
            )
        }
    }

    private static let state = OSAllocatedUnfairLock(initialState: Counts())

    static var counts: Counts { state.withLock { $0 } }

    static func recordLaunch(executableURL: URL) {
        let name = executableURL.lastPathComponent
        state.withLock { counts in
            switch name {
            case "git": counts.gitLaunches += 1
            case "gh": counts.ghLaunches += 1
            default: counts.otherLaunches += 1
            }
        }
    }

    static func recordProcessTableScan() {
        state.withLock { $0.processTableScans += 1 }
    }
}
