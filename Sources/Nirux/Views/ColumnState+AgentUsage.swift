import AppKit

/// Transcript a column follows, and the `claude` process whose session it
/// records.
struct ClaudeTranscriptFollow {
    let sessionID: String
    let process: ProcessInstance
    let follower: ClaudeUsageFollower

    enum Step: Equatable {
        /// The session's `claude` is in the foreground: read and show.
        case read
        /// A shell may only mean it is suspended (Ctrl-Z): hide, keep.
        case hide
        /// Another `claude` replaced it; that one's hooks will name its own
        /// transcript.
        case stop
    }

    func step(foregroundProcess: ForegroundProcess?) -> Step {
        if foregroundProcess?.instance == process { return .read }
        return foregroundProcess?.name == "claude" ? .stop : .hide
    }
}

/// "ctx 62%" in the column title bar: the context and token usage of the
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
            follower: ClaudeUsageFollower(path: path)
        )
        setAgentUsage(nil)
    }

    /// Heartbeat, for columns on screen: read what the transcript gained.
    func refreshAgentUsage(snapshot: ProcessSnapshot) {
        guard let follow = claudeTranscript else { return }
        switch follow.step(foregroundProcess: pty?.foregroundProcess(snapshot: snapshot)) {
        case .read:
            let follower = follow.follower
            follower.refresh { [weak self] usage in
                guard let self, self.claudeTranscript?.follower === follower else { return }
                self.setAgentUsage(usage)
            }
        case .hide:
            setAgentUsage(nil)
        case .stop:
            follow.follower.cancel()
            claudeTranscript = nil
            setAgentUsage(nil)
        }
    }

    func setAgentUsage(_ usage: ClaudeSessionUsage?) {
        guard usage != agentUsage else { return }
        agentUsage = usage
        if let usage, let text = usage.titleBarText {
            let label = usageLabel ?? makeUsageLabel()
            label.stringValue = text
            label.textColor = usage.isNearlyFull
                ? NSColor.systemOrange.withAlphaComponent(0.9)
                : NSColor.white.withAlphaComponent(0.45)
            label.toolTip = usage.tooltip
        }
        layoutTitleBarContents()
    }

    private func makeUsageLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        label.alignment = .right
        label.isBezeled = false
        label.drawsBackground = false
        label.setAccessibilityLabel("Claude context usage")
        titleBar?.addSubview(label)
        usageLabel = label
        return label
    }
}
