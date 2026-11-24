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
    /// A turn that takes in a claimed message calls the model after the
    /// claim: a Stop closer to it ends the turn that was finishing.
    static let turnAfterClaim: TimeInterval = 1
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
    /// without either.
    @MainActor
    static func claudeHooks(
        executable: String? = NiruxShellView.niruxExecutable,
        version: ClaudeCodeVersion? = ClaudeCodeVersion.detect(),
        mailbox: URL = mailbox.root
    ) -> [String: [ClaudeSpaceSettings.File.HookGroup]]? {
        guard let executable, let version, version >= claudeVersion else { return nil }
        let path = AgentHookInstaller.shellQuoted(executable)
        let command = #"if [ -n "$NIRUX_AGENT_UUID" ] && [ -x \#(path) ]; then exec \#(path) --hook mission-wait "#
            + AgentHookInstaller.shellQuoted(mailbox.path) + "; else /bin/cat >/dev/null; fi"
        let waiter = ClaudeSpaceSettings.File.HookGroup(hooks: [
            .init(command: command, asyncRewake: true, timeout: timeout, rewakeSummary: summary, rewakeMessage: preamble)
        ])
        return ["SessionStart": [waiter], "Stop": [waiter]]
    }

    /// Waits on the letters of its payload's session while its `claude`
    /// runs it: 2 with them on stderr, else 0. A second waiter on the
    /// session leaves at once.
    static func run(mailbox root: String) -> Int32 {
        let parent = getppid()
        let payload = FileHandle.standardInput.readDataToEndOfFile()
        guard parent > 1, AgentHookCLI.isFromNiruxTerminal(env: ProcessInfo.processInfo.environment),
              let session = ((try? JSONSerialization.jsonObject(with: payload)) as? [String: Any])?["session_id"] as? String
        else { return 0 }
        let mailbox = MissionMailbox(root: URL(fileURLWithPath: root, isDirectory: true))
        // The waiter of a conversation this claude left (/clear, /resume) leaves.
        try? mailbox.noteRunning(session, in: parent)
        guard let waiter = try? mailbox.arm(session) else { return 0 }
        let letters = withExtendedLifetime(waiter) {
            mailbox.letters(for: session, whileRunning: parent, until: Date() + TimeInterval(timeout - 60))
        }
        guard !letters.isEmpty else { return 0 }
        FileHandle.standardError.write(Data(letters.map(\.text).joined(separator: "\n\n").utf8))
        return 2
    }
}
