import Foundation

/// Sizing debug trace, enabled with NIRUX_TERM_DEBUG=1. Timestamps match
/// TerminalDebugLog so both traces can be interleaved when diagnosing
/// layout/PTY winsize issues.
enum NiruxDebugLog {
    static let isEnabled = ProcessInfo.processInfo.environment["NIRUX_TERM_DEBUG"] != nil

    static func log(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        print("[Nirux][\(String(format: "%.3f", Date().timeIntervalSince1970))] \(message())")
    }
}
