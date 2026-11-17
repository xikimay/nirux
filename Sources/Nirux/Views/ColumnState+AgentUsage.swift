import AppKit

/// Transcript a column follows, and the `claude` process whose session it
/// records.
struct ClaudeTranscriptFollow {
    let sessionID: String
    let process: ProcessInstance
    let follower: ClaudeUsageFollower
    /// Last heartbeat saw the session's `claude` in the foreground: a read
    /// finishing after it left must not show the label again.
    var isInForeground = false

    enum Step: Equatable {
        /// The session's `claude` is in the foreground: read and show.
        case read
        /// It still runs elsewhere — suspended (Ctrl-Z) behind a shell:
        /// hide, keep.
        case hide
        /// It exited, or another `claude` replaced it (whose hooks will
        /// name its own transcript).
        case stop
    }

    /// `foregroundName` is only asked for when the process still runs but
    /// isn't in the foreground: resolving a name reads the process's
    /// arguments.
    func step(
        foreground: ProcessInstance?,
        isRunning: Bool,
        foregroundName: () -> String?
    ) -> Step {
        if foreground == process { return .read }
        guard isRunning else { return .stop }
        return foregroundName() == "claude" ? .stop : .hide
    }
}

/// "ctx 62%" in the column header: the context and token usage of the
/// column's Claude session, read from its transcript (read-only, off the
/// main thread — see `ClaudeUsageFollower`). Shown only while the
/// session's own `claude` is the column's foreground process.
extension ColumnState {
    /// A hook of the session bound to the foreground `claude` named its
    /// transcript (see `admitClaudeHook`).
    func followClaudeTranscript(at path: String, sessionID: String, process: ProcessInstance) {
        if let current = claudeTranscript, current.follower.path == path, current.process == process { return }
        claudeTranscript?.follower.cancel()
        claudeTranscript = ClaudeTranscriptFollow(
            sessionID: sessionID,
            process: process,
            follower: ClaudeUsageFollower(path: path, owner: self)
        )
        setAgentUsage(nil)
    }

    /// While Claude's turn waits on the model, its transcript growing is a
    /// sign of life (`AgentLifeSigns`): its size, never its text.
    func noteTranscriptGrowth(foreground: ForegroundProcess?) {
        guard let pty, let follow = claudeTranscript, follow.process == foreground?.instance,
              pty.agentAwaitsModel(foreground: foreground),
              let stamp = FileStamp(URL(fileURLWithPath: follow.follower.path))
        else { return }
        pty.noteAgentTranscript(path: follow.follower.path, size: stamp.size)
    }

    /// Heartbeat, for columns on screen: read what the transcript gained.
    func refreshAgentUsage(snapshot: ProcessSnapshot) {
        // An empty snapshot (failed sysctl) would read as "exited".
        guard let follow = claudeTranscript, let pty, !snapshot.isEmpty else { return }
        let step = follow.step(
            foreground: pty.foregroundInstance(snapshot: snapshot),
            isRunning: snapshot.contains(follow.process),
            foregroundName: { pty.foregroundProcess(snapshot: snapshot)?.name }
        )
        switch step {
        case .read:
            claudeTranscript?.isInForeground = true
            let follower = follow.follower
            follower.refresh { [weak self] usage in
                guard let self, let current = self.claudeTranscript,
                      current.follower === follower, current.isInForeground else { return }
                self.setAgentUsage(usage)
            }
        case .hide:
            claudeTranscript?.isInForeground = false
            setAgentUsage(nil)
        case .stop:
            follow.follower.cancel()
            claudeTranscript = nil
            setAgentUsage(nil)
        }
    }

    /// Shown in the header's accessories, before the dev-server chip; an
    /// empty label takes no room.
    func setAgentUsage(_ usage: ClaudeSessionUsage?) {
        guard usage != agentUsage else { return }
        agentUsage = usage
        if let usage, let text = usage.headerText {
            let label = usageLabel ?? makeUsageLabel()
            label.stringValue = usage.isNearlyFull ? text.asWarning : text
            label.shortText = usage.isNearlyFull ? text : nil
            label.textColor = usage.isNearlyFull ? .niruxWarning : Theme.Color.textTertiary
            label.toolTip = usage.tooltip
        } else {
            usageLabel?.stringValue = ""
        }
        terminalHeader?.layoutNow()
    }

    private func makeUsageLabel() -> ColumnHeaderLabel {
        let label = ColumnHeaderLabel()
        label.setAccessibilityLabel("Claude context usage")
        terminalHeader?.accessories.insert(label, at: 0)
        usageLabel = label
        return label
    }
}
