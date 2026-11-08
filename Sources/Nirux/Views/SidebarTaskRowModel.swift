import Foundation

/// What a task row says under its title (docs/spaces.md, Interface): the
/// one thing to know first. Amber only when the user is needed.
struct SidebarStatusLine: Hashable {
    enum Tone: Hashable {
        /// An agent waits on the user: amber.
        case needsYou
        /// An agent stopped, a check failed: red.
        case error
        /// What goes on: grey.
        case neutral
        /// Nothing goes on: the branch, dimmer, in the machine font.
        case branch
    }

    /// What a click on the line does; nil: the row's click.
    enum Action: Hashable {
        /// The Mission question popover.
        case missionQuestion(columnIndex: Int)
        /// A pull request or a check, in a browser column of the workspace.
        case open(url: String)
        /// "Clean up" a merged pull request's worktree.
        case cleanUp
    }

    let text: String
    let tone: Tone
    var action: Action?
}

/// The sign before a row's title, in the state dots' column.
enum SidebarRowMark: Hashable {
    case needsYou, error, working, asking, readyToMerge, merged, idle
}

/// A task row's two lines, before any view exists.
struct SidebarRowSummary: Hashable {
    let mark: SidebarRowMark
    let status: SidebarStatusLine
    /// At the end of the title line: how long since the last activity (how
    /// long it has waited, how long the turn has run), or the pull request
    /// a "Ready to merge" or "Merged" line doesn't name.
    let trailing: String?
}

@MainActor
extension WorkspaceInfo {
    /// Needs you, then broken, then a Mission question the parent may still
    /// answer, then work, then the pull request, then a finished turn, else
    /// the branch.
    var rowSummary: SidebarRowSummary {
        let age = lastActivityAt.map { SidebarView.cardAge(since: $0) }
        func row(_ mark: SidebarRowMark, _ text: String, _ tone: SidebarStatusLine.Tone,
                 _ action: SidebarStatusLine.Action? = nil, trailing: String? = nil) -> SidebarRowSummary {
            SidebarRowSummary(mark: mark, status: SidebarStatusLine(text: text, tone: tone, action: action), trailing: trailing ?? age)
        }

        if let waiting = columns.first(where: { $0.attention == .waiting }) {
            if let question = waiting.missionQuestion, question.handOff != nil, !question.isAnswered {
                return row(.needsYou, "Needs you · a question", .needsYou, .missionQuestion(columnIndex: waiting.index))
            }
            return row(.needsYou, "Needs you · \(Self.needsYouDetail(waiting))", .needsYou)
        }
        if let broken = columns.first(where: { $0.attention == .error }), let summary = broken.attentionSummary {
            return row(.error, Self.sentence(summary.headline), .error)
        }
        if let pullRequest = prInfo, pullRequest.state == "OPEN", pullRequest.ciStatus == "FAILURE",
           !columns.contains(where: { $0.agentStatus == .working }) {
            let url = pullRequest.failedCheckUrl ?? "\(pullRequest.url)/checks"
            return row(.error, "#\(pullRequest.number) · checks failed", .error, .open(url: url))
        }
        if let asking = columns.first(where: { $0.missionQuestion != nil }), let question = asking.missionQuestion {
            let text = question.isAnswered
                ? (question.parentTitle == "you" ? "Your answer is ready to type in" : "Answer from \(question.parentTitle) ready to type in")
                : "Asking \(question.parentTitle)"
            return row(.asking, text, .neutral, question.isAnswered ? nil : .missionQuestion(columnIndex: asking.index))
        }
        let working = columns.filter { $0.agentStatus == .working }
        if !working.isEmpty {
            return row(.working, "Working", .neutral, trailing: working.compactMap(\.elapsedDisplay).first ?? age)
        }
        if let pullRequest = prInfo, let summary = Self.pullRequestRow(pullRequest, cleanup: mergedCleanup, age: age) {
            return summary
        }
        if columns.contains(where: { $0.attention == .finished }) {
            return row(.idle, "Done", .neutral)
        }
        if columns.contains(where: { $0.deferredAgent != nil }) {
            return row(.idle, "Paused", .neutral)
        }
        let place = gitBranch ?? columns.first(where: \.isFocused)?.abbreviatedCwd ?? columns.first?.abbreviatedCwd
        return row(.idle, place ?? "No activity yet", place == nil ? .neutral : .branch)
    }

    /// The command to allow, the question, else what the agent waits on.
    private static func needsYouDetail(_ column: ColumnInfo) -> String {
        if let approval = column.permissionApproval, approval.toolName != "ExitPlanMode",
           let text = AgentText.clean(approval.text, maxLength: 300) {
            return text
        }
        let label = column.attentionLabel
        if let detail = column.attentionSummary?.detail, !detail.isEmpty, label != "plan" { return detail }
        switch label {
        case "question": return "a question"
        case "plan": return "plan approval"
        case "permission": return "permission"
        default: return "a reply"
        }
    }

    /// "stopped on an API error" → "Stopped on an API error".
    private static func sentence(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }

    /// An open or merged pull request's line; nil for a closed one. "Ready
    /// to merge": checks passed, GitHub says it merges cleanly, and no
    /// review is asked for or asks for changes.
    private static func pullRequestRow(_ pullRequest: PRInfo, cleanup: MergedCleanupOffer?, age: String?) -> SidebarRowSummary? {
        let number = "#\(pullRequest.number)"
        func row(_ mark: SidebarRowMark, _ text: String, _ action: SidebarStatusLine.Action?, trailing: String?) -> SidebarRowSummary {
            SidebarRowSummary(mark: mark, status: SidebarStatusLine(text: text, tone: .neutral, action: action), trailing: trailing)
        }
        let open = SidebarStatusLine.Action.open(url: pullRequest.url)
        switch pullRequest.state {
        case "MERGED":
            switch cleanup {
            case .available?: return row(.merged, "Merged · Clean up", .cleanUp, trailing: number)
            case .inProgress?: return row(.merged, "Merged · cleaning up…", nil, trailing: number)
            case nil: return row(.merged, "Merged", open, trailing: number)
            }
        case "OPEN":
            if pullRequest.isDraft { return row(.idle, "\(number) · draft", open, trailing: age) }
            switch pullRequest.ciStatus {
            case "PENDING"?: return row(.idle, "\(number) · checks running", .open(url: "\(pullRequest.url)/checks"), trailing: age)
            case "SUCCESS"?:
                let reviewBlocks = ["REVIEW_REQUIRED", "CHANGES_REQUESTED"].contains(pullRequest.reviewDecision ?? "")
                guard pullRequest.mergeable == "MERGEABLE", !reviewBlocks else {
                    return row(.idle, "\(number) · checks passed", open, trailing: age)
                }
                return row(.readyToMerge, "Ready to merge", open, trailing: number)
            default:
                return row(.idle, "\(number) · open", open, trailing: age)
            }
        default:
            return nil
        }
    }
}
