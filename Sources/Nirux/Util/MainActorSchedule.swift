import Foundation

/// Runs `work` on the main actor after the delay. Types that take one
/// default to `mainQueueSchedule`; tests pass a clock they advance by hand.
/// There is no cancellation: callers void stale work with a generation.
typealias MainActorSchedule = @MainActor (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> Void

@MainActor let mainQueueSchedule: MainActorSchedule = { delay, work in
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
        MainActor.assumeIsolated { work() }
    }
}
