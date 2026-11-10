import Foundation

/// A `cat` under an agent's name, for tests that type into a real terminal:
/// what it is sent goes to a file the test reads, byte by byte. The
/// terminal's line mode is off: left on, text typed without Return would
/// never get there, nor anything of a line over 1,024 bytes.
struct AgentStandIn {
    let received = FileManager.default.temporaryDirectory
        .appendingPathComponent("nirux-agent-stand-in-\(UUID().uuidString).txt")

    /// The shell command that becomes it.
    func command(named name: String = "claude") -> String {
        "stty -icanon min 1 time 0; exec -a \(name) /bin/cat > '\(received.path)'"
    }

    /// What it was sent so far.
    var input: String {
        (try? String(contentsOf: received, encoding: .utf8)) ?? ""
    }

    func remove() {
        try? FileManager.default.removeItem(at: received)
    }
}
