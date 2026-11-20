import Foundation
@testable import Nirux

/// The steps a shell times (`ShellSideEffects.afterCommit`), held until
/// the test runs them: a test waits on state, never on a time.
@MainActor
final class TimedSteps {
    private var pending: [(duration: CFTimeInterval, step: @MainActor () -> Void)] = []

    init(on shell: NiruxShellView) {
        shell.sideEffects.afterCommit = { [weak self] duration, step in self?.pending.append((duration, step)) }
    }

    var durations: [CFTimeInterval] { pending.map(\.duration) }

    /// Runs the oldest step held; false when none is.
    @discardableResult
    func runNext() -> Bool {
        guard !pending.isEmpty else { return false }
        pending.removeFirst().step()
        return true
    }
}
