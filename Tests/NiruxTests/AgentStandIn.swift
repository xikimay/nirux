import Foundation

/// A `cat` under an agent's name, for tests that type into a real terminal:
/// what it is sent goes to a file the test reads, byte by byte. The
/// terminal's line mode is off: left on, text typed without Return would
/// never get there, nor anything of a line over 1,024 bytes.
struct AgentStandIn {
    let received = FileManager.default.temporaryDirectory
        .appendingPathComponent("nirux-agent-stand-in-\(UUID().uuidString).txt")
    private let held = FileManager.default.temporaryDirectory
        .appendingPathComponent("nirux-agent-stand-in-\(UUID().uuidString).held")

    /// The shell command that becomes it. `holdable`: it takes 128 bytes at
    /// a time; after `hold()`, one more read, then none until `release()`
    /// (20 s at most from that read: an app that waited on it fails rather
    /// than hangs), as an agent busy drawing. `launchPrompt` (no single quote in it): its last argument,
    /// as an agent launched with a prompt has.
    /// `arguments` (no single quote in them) come before it.
    func command(named name: String = "claude", holdable: Bool = false, arguments: [String] = [], launchPrompt: String? = nil) -> String {
        guard holdable || launchPrompt != nil || !arguments.isEmpty else {
            return "stty -icanon min 1 time 0; exec -a \(name) /bin/cat > '\(received.path)'"
        }
        let wait = holdable ? #" my $s = time; select(undef, undef, undef, 0.02) while -e "\#(held.path)" && time - $s < 20;"# : ""
        let reader = #"open(my $o, ">", $ARGV[0]); $o->autoflush(1); "#
            + #"while (sysread(STDIN, my $b, 128)) { print $o $b;"# + wait + " }"
        let prompt = (arguments + (launchPrompt.map { [$0] } ?? [])).map { " '\($0)'" }.joined()
        return "stty -icanon min 1 time 0; exec -a \(name) /usr/bin/perl -e '\(reader)' '\(received.path)'\(prompt)"
    }

    /// What it was sent so far.
    var input: String {
        (try? String(contentsOf: received, encoding: .utf8)) ?? ""
    }

    /// What is sent meanwhile, past its next read, waits in the terminal's
    /// input queue.
    func hold() {
        FileManager.default.createFile(atPath: held.path, contents: nil)
    }

    func release() {
        try? FileManager.default.removeItem(at: held)
    }

    func remove() {
        try? FileManager.default.removeItem(at: received)
        release()
    }
}
