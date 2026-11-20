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
        /// What runs the conversation's `codex`, so that the same build
        /// takes it (`command(of:)`).
        let command: [String]
        let thread: String
        let message: String
        /// The `CODEX_HOME` that `codex` runs with, where it keeps its
        /// threads and its queue: a shell may set one Nirux doesn't have.
        var codexHome: String?
    }

    enum Outcome: Equatable, Sendable {
        case queued
        /// Codex didn't take it, with the first line it said why.
        case refused(String)
        /// It didn't answer within `timeout`: it may hold the message.
        case unconfirmed
    }

    /// It answers within a few seconds, the time to start its app server.
    nonisolated static let timeout: TimeInterval = 30

    /// What runs `process`, a `codex`: its executable, or the runtime and
    /// script it is (npm's `node …/bin/codex` on a Node that can't replace
    /// itself with the binary). Nil once it is gone.
    nonisolated static func command(of process: ForegroundProcess) -> [String]? {
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(process.instance.pid, &path, UInt32(path.count)) > 0 else { return nil }
        return command(executable: String(cString: path), arguments: process.arguments)
    }

    nonisolated static func command(executable: String, arguments: [String]) -> [String] {
        func name(_ path: String) -> String { ((path as NSString).lastPathComponent as NSString).deletingPathExtension }
        guard ProcessSnapshot.runtimeBinaries.contains(name(executable)),
              let script = arguments.dropFirst().first(where: { name($0) == CodingAgent.codex.rawValue }) else { return [executable] }
        return [executable, script]
    }

    /// Runs `request` off the main thread; `done` comes on the main queue.
    nonisolated static func send(_ request: Request, done: @escaping @MainActor @Sendable (Outcome) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = run(request)
            DispatchQueue.main.async { done(outcome) }
        }
    }

    /// The arguments after `request`'s executable. The `=` forms keep a
    /// message starting with "-" a value.
    nonisolated static func arguments(for request: Request) -> [String] {
        request.command.dropFirst() + ["queue", "--thread=" + request.thread, "--message=" + request.message]
    }

    /// What `codex queue` runs with over Nirux's environment.
    nonisolated static func environment(for request: Request) -> [String: String] {
        request.codexHome.map { ["CODEX_HOME": $0] } ?? [:]
    }

    private nonisolated static func run(_ request: Request) -> Outcome {
        guard let executable = request.command.first else { return .refused("no codex to run") }
        guard let result = BoundedProcess.execute(
            executableURL: URL(fileURLWithPath: executable),
            arguments: arguments(for: request),
            currentDirectoryURL: FileManager.default.homeDirectoryForCurrentUser,
            environment: .inherited(adding: environment(for: request)),
            timeout: timeout,
            captureStandardError: true
        ) else { return .refused("Nirux couldn't run \(executable)") }
        guard result.stop == nil, let status = result.terminationStatus else { return .unconfirmed }
        guard status != 0 else { return .queued }
        let said = String(decoding: result.standardError + result.standardOutput, as: UTF8.self)
            .split(whereSeparator: \.isNewline).first.map { String($0.prefix(200)) }
        return .refused(said ?? "codex exited with status \(status)")
    }
}
