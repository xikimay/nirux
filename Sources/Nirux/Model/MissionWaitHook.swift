import Foundation
import NiruxCore

/// `Nirux --hook mission-wait <mailbox>`: how a `claude` gets its Mission
/// messages without typing (docs/design/mission-delivery.md). Claude Code
/// runs it in the background (`asyncRewake`) as a session starts and at each
/// turn end. It waits on the session's letters, prints them and exits 2:
/// Claude Code wakes the model with them, idle or at its next step mid-turn,
/// and a draft in the prompt stays the user's.
enum MissionWaitHook {
    /// The first Claude Code it was proven on. One that doesn't run it in the
    /// background would wait on it for a day at each session start.
    static let claudeVersion = ClaudeCodeVersion(major: 2, minor: 1, patch: 331)
    /// Claude Code's timeout for one waiter, in seconds. The waiter leaves a
    /// minute before: one Claude Code kills could have claimed a message
    /// it never printed.
    static let timeout = 86_400
    /// What the user sees of a message in the agent's terminal: its text is
    /// behind ctrl+o.
    static let summary = "Nirux Mission message"
    /// What the model reads before it, in place of Claude Code's "Stop hook
    /// blocking error from command …". The agent acts on a message only when
    /// it knows where it comes from: its handover says Nirux brings them in
    /// this way (`NiruxShellView.typedAnswerMission`).
    static let preamble = "Nirux Mission message. Nirux, the app that runs this session for the user, brings it in here "
        + "instead of typing it into your prompt:"

    static var mailbox: MissionMailbox {
        MissionMailbox(root: Persistence.stateDirectory.appendingPathComponent("mission-mailbox", isDirectory: true))
    }

    /// The hooks a space's Claude settings run, for the oldest `claude` a
    /// terminal could run (`version`) and Nirux at `executable`; nil
    /// without either, or with the pilot off in Settings (`enabled`).
    static func claudeHooks(
        executable: String?, enabled: Bool, version: @autoclosure () -> ClaudeCodeVersion? = ClaudeCodeVersion.detect(),
        mailbox: URL = mailbox.root
    ) -> [String: [ClaudeSpaceSettings.File.HookGroup]]? {
        // Detected only then: it reads every claude install on the PATH.
        guard enabled, let executable, let version = version(), version >= claudeVersion else { return nil }
        let path = AgentHookInstaller.shellQuoted(executable)
        let command = #"if [ -n "$NIRUX_AGENT_UUID" ] && [ -x \#(path) ]; then exec \#(path) --hook mission-wait "#
            + AgentHookInstaller.shellQuoted(mailbox.path) + "; else /bin/cat >/dev/null; fi"
        let waiter = ClaudeSpaceSettings.File.HookGroup(hooks: [
            .init(command: command, asyncRewake: true, timeout: timeout, rewakeSummary: summary, rewakeMessage: preamble)
        ])
        return ["SessionStart": [waiter], "Stop": [waiter]]
    }

    /// The command: Claude Code's payload on stdin, its `claude` as the parent.
    static func run(mailbox root: String) -> Int32 {
        run(
            mailbox: MissionMailbox(root: URL(fileURLWithPath: root, isDirectory: true)),
            payload: FileHandle.standardInput.readDataToEndOfFile(), environment: ProcessInfo.processInfo.environment,
            parent: getppid(), until: Date() + TimeInterval(timeout - 60)
        ) { FileHandle.standardError.write(Data($0.utf8)) }
    }

    /// Waits on the letters of `payload`'s session while `parent` runs it,
    /// until `deadline` (a minute before Claude Code's timeout, so a kill
    /// never lands between a claim and its print): 2 with them printed, else
    /// 0. A second waiter on the session leaves at once.
    static func run(
        mailbox: MissionMailbox, payload: Data, environment: [String: String], parent: pid_t, until deadline: Date,
        print: (String) -> Void
    ) -> Int32 {
        guard parent > 1, AgentHookCLI.isFromNiruxTerminal(env: environment),
              let fields = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
              let session = fields["session_id"] as? String
        else { return 0 }
        // The waiter of a conversation this claude left (/clear, /resume) leaves.
        try? mailbox.noteRunning(session, in: parent)
        if let transcript = (fields["transcript_path"] as? String).flatMap(AgentHookEvent.validTranscriptPath) {
            try? mailbox.noteTranscript(transcript, of: session)
        }
        guard let waiter = try? mailbox.arm(session) else { return 0 }
        let letters = withExtendedLifetime(waiter) { mailbox.letters(for: session, whileRunning: parent, until: deadline) }
        guard !letters.isEmpty else { return 0 }
        print(letters.map(\.text).joined(separator: "\n\n"))
        return 2
    }

    /// Whether the model took `letter`, claimed at `claimedAt`, in: a line of
    /// the turn that read it holds its text in `transcript`, past where the
    /// transcript ended when it was posted. Claude Code writes it as the
    /// model reads it, mid-turn too; the line it queues the hook's output
    /// with doesn't count. Off the main thread: a transcript passes 100 MB.
    static func modelRead(_ letter: MissionMailbox.Letter, claimedAt: TimeInterval, transcript path: String?) -> Bool {
        guard let path, let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped) else { return false }
        let needle = Data(jsonEscaped(String(String.UnicodeScalarView(letter.text.unicodeScalars.prefix(200)))).utf8)
        guard !needle.isEmpty else { return false }
        let offset = letter.transcriptOffset.map { Int(clamping: $0) }.flatMap { $0 <= data.count ? $0 : nil } ?? 0
        var start = data.startIndex + offset
        while start < data.endIndex, let found = data.range(of: needle, in: start..<data.endIndex) {
            let lineStart = data[..<found.lowerBound].lastIndex(of: 0x0A).map { $0 + 1 } ?? data.startIndex
            let lineEnd = data[found.upperBound...].firstIndex(of: 0x0A) ?? data.endIndex
            if let line = (try? JSONSerialization.jsonObject(with: data[lineStart..<lineEnd])) as? [String: Any],
               ["user", "attachment"].contains(line["type"] as? String),
               (line["timestamp"] as? String).flatMap(transcriptTime).map({ $0 >= claimedAt - 1 }) ?? false {
                return true
            }
            start = lineEnd
        }
        return false
    }

    /// `text` as JSON.stringify writes it in a transcript, without quotes.
    static func jsonEscaped(_ text: String) -> String {
        var escaped = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": escaped += "\\\""
            case "\\": escaped += "\\\\"
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            case "\u{08}": escaped += "\\b"
            case "\u{0C}": escaped += "\\f"
            case _ where scalar.value < 0x20: escaped += String(format: "\\u%04x", scalar.value)
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        return escaped
    }

    private static func transcriptTime(_ text: String) -> TimeInterval? {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return format.date(from: text)?.timeIntervalSince1970
    }
}
