import Foundation

/// A `cat` under an agent's name, for tests that type into a real terminal:
/// what it is sent goes to a file the test reads. A line gets there once
/// its line feed, or Return, is typed: not the last line of a paste left
/// without Return, and nothing of a line over 1,024 bytes (the terminal
/// holds it back, and what follows).
struct AgentStandIn {
    let received = FileManager.default.temporaryDirectory
        .appendingPathComponent("nirux-agent-stand-in-\(UUID().uuidString).txt")

    /// The shell command that becomes it.
    func command(named name: String = "claude") -> String {
        "exec -a \(name) /bin/cat > '\(received.path)'"
    }

    /// What it was sent so far.
    var input: String {
        (try? String(contentsOf: received, encoding: .utf8)) ?? ""
    }

    func remove() {
        try? FileManager.default.removeItem(at: received)
    }
}
