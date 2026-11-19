import Darwin
import Foundation

/// Hands a message to a running Codex through its own queue,
/// `codex queue --thread <id> --message <text>` (codex 0.167): Codex keeps
/// it with the thread and starts it as a prompt once that conversation is
/// idle, and not after an Esc. Nothing reaches the terminal, so no dialog
/// or draft can take it. Seen live: an idle Codex started it at once, a
/// draft stayed untouched, a busy one finished its turn first.
enum CodexQueue {
    struct Request: Equatable, Sendable {
        /// The `codex` running the conversation: the same build takes it.
        let executable: String
        let thread: String
        let message: String
    }

    enum Outcome: Equatable, Sendable {
        case queued
        /// Codex didn't take it, with the first line it said why.
        case refused(String)
    }

    /// It answers within a few seconds, the time to start its app server.
    nonisolated static let timeout: TimeInterval = 30

    /// The executable of `process`, nil once it is gone.
    nonisolated static func executable(of process: ProcessInstance) -> String? {
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(process.pid, &path, UInt32(path.count)) > 0 else { return nil }
        return String(cString: path)
    }

    /// Runs `request` off the main thread; `done` comes on the main queue.
    nonisolated static func send(_ request: Request, done: @escaping @MainActor @Sendable (Outcome) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = run(request)
            DispatchQueue.main.async { done(outcome) }
        }
    }

    private nonisolated static func run(_ request: Request) -> Outcome {
        guard let result = BoundedProcess.run(
            executableURL: URL(fileURLWithPath: request.executable),
            arguments: ["queue", "--thread", request.thread, "--message", request.message],
            currentDirectoryURL: FileManager.default.homeDirectoryForCurrentUser,
            timeout: timeout,
            captureStandardError: true
        ) else { return .refused("codex didn't answer within \(Int(timeout)) seconds") }
        guard result.terminationStatus != 0 else { return .queued }
        let said = String(decoding: result.standardError + result.standardOutput, as: UTF8.self)
            .split(whereSeparator: \.isNewline).first.map { String($0.prefix(200)) }
        return .refused(said ?? "codex exited with status \(result.terminationStatus)")
    }
}
