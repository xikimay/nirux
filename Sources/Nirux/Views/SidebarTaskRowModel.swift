import Foundation

/// What a task row says under its title (docs/design/spaces.md, Interface): the
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

    /// What a click on the line (or on its `linkText`) does; nil: the
    /// row's click. A pull request's line stays the row's: it's where one
    /// clicks to switch rows (the selected row has the links).
    enum Action: Hashable {
        /// The Mission question popover.
        case missionQuestion(columnIndex: Int)
        /// "Clean up" a merged pull request's worktree.
        case cleanUp
        /// "Resume" a restored agent here, without switching rows.
        case resume(columnIndex: Int, columnID: UUID)
    }

    let text: String
    let tone: Tone
    var action: Action?
    /// The end of `text` that is the link ("Clean up"); nil: all of it.
    var linkText: String?
    /// What the line can't hold, for its tooltip.
    var detail: String?
}

/// The sign before a row's title, in the state dots' column.
enum SidebarRowMark: Hashable, CaseIterable {
    case needsYou, error, working, asking, blocked, readyToMerge, merged, idle
    /// A finished turn the user hasn't looked at yet, its status line
    /// beside it: a grey check where the grey dot is.
    case finished
    /// The pull request's checks run: a ring that turns, then the check of
    /// `readyToMerge` or the red of `error`.
    case checksRunning
}

/// A task row's two lines, before any view exists.
struct SidebarRowSummary: Hashable {
    /// What the time at the end of the title line counts.
    enum Trailing: Hashable {
        /// Since the last activity: how long it has waited, or sat.
        case age(String)
        /// How long the working agent's turn has run.
        case turn(String)
        /// The pull request a "Ready to merge" or "Merged" line doesn't name.
        case pullRequest(Int)

        var text: String {
            switch self {
            case .age(let text), .turn(let text): return text
            case .pullRequest(let number): return "#\(number)"
            }
        }
    }

    /// A block under the row that has the status whole, over what answers
    /// it: the line itself then stays short.
    enum Block: Hashable {
        /// Allow / Deny, the command in its box: the line keeps to one
        /// line.
        case request
        /// A turn's question over its buttons, a dialog's over its
        /// options: the line says "Needs you · a question".
        case question
    }

    let mark: SidebarRowMark
    let status: SidebarStatusLine
    let trailing: Trailing?
    /// The column a click on the row brings up: the one that waits on the
    /// user, broke, or may be going in circles. Nil: the workspace's
    /// focused column.
    var focusColumn: Int?
    /// The block that says the status whole, if one does.
    var saidBelow: Block?

    /// What the status line prints: the status, or less under a block that
    /// has it whole. `status.text` stays what the row says where no block
    /// follows (the catch-up card, a tooltip).
    var lineText: String {
        saidBelow == .question ? "Needs you · a question" : status.text
    }

    /// How many lines the status may take before "…". What stops a task
    /// is read whole (four lines): it waits on the user, something broke,
    /// a blocker; and so is the selected row's line. Any other row gets
    /// two. A branch, a line that ends on a link ("Merged · Clean up") and
    /// a line its block repeats keep to one.
    func statusLineLimit(isSelected: Bool) -> Int {
        if status.tone == .branch || status.linkText != nil || saidBelow != nil { return 1 }
        return isSelected || [.needsYou, .error, .blocked].contains(mark) ? 4 : 2
    }
}

@MainActor
extension WorkspaceInfo {
    /// Needs you, then broken, then a Mission question the parent may still
    /// answer, then work (in the same grey, that the agent may be going in
    /// circles: it doesn't ask the user either), then an agent to resume,
    /// then the blocker (grey: it doesn't ask the user), then a finished
    /// turn, then the pull request, then the next step, then where the
    /// task stands, else the branch.
    var rowSummary: SidebarRowSummary {
        let age = lastActivityAt.map { SidebarRowSummary.Trailing.age(SidebarView.cardAge(since: $0)) }
        func row(_ mark: SidebarRowMark, _ text: String, _ tone: SidebarStatusLine.Tone,
                 _ action: SidebarStatusLine.Action? = nil, trailing: SidebarRowSummary.Trailing? = nil) -> SidebarRowSummary {
            SidebarRowSummary(mark: mark, status: SidebarStatusLine(text: text, tone: tone, action: action), trailing: trailing ?? age)
        }

        if let waitingTask {
            if case .needsYou = waitingTask { return row(.needsYou, waitingTask.line, .needsYou) }
            return row(.blocked, waitingTask.line, .neutral)
        }
        let step = agentStep
        if case .needsYou(let waiting, let words, let isHandedOff)? = step {
            var summary: SidebarRowSummary
            if isHandedOff {
                // The question itself: a click on it opens the reply popover.
                summary = row(.needsYou, "Needs you · \(words)", .needsYou, .missionQuestion(columnIndex: waiting.index))
            } else {
                summary = row(.needsYou, "Needs you · \(words)", .needsYou)
                // Its block has it whole: the command in its box, the
                // question over its buttons.
                if waiting.permissionApproval != nil {
                    summary.saidBelow = .request
                } else if waiting.turnQuestion != nil || waiting.dialog != nil {
                    summary.saidBelow = .question
                }
            }
            summary.focusColumn = waiting.index
            return summary
        }
        if case .broken(let broken, let sentence)? = step {
            var summary = row(.error, sentence, .error)
            summary.focusColumn = broken.index
            return summary
        }
        // The pull request's follow-up handed it over: the user's now.
        if case .stopped(let words)? = followUp, !columns.contains(where: { $0.agentStatus == .working }) {
            return row(.needsYou, "Needs you · \(words)", .needsYou)
        }
        if let pullRequest = prInfo, pullRequest.state == .open, pullRequest.ciStatus == "FAILURE",
           !columns.contains(where: { $0.agentStatus == .working }) {
            // Only a likely flake says more (docs/design/ci-failure-triage.md).
            return row(.error, "#\(pullRequest.number) · checks failed" + (ciFlakyReason == nil ? "" : " · likely flaky"), .error)
        }
        // A child that asked ended its turn to wait (a Codex one blocks):
        // asking comes before work. An answer waiting to be typed comes
        // after: a Claude restarted since works through the user's prompt.
        if case .asking(let asking, let pending)? = step {
            return row(.asking, "Asking \(pending.parentTitle)", .neutral, .missionQuestion(columnIndex: asking.index))
        }
        if case .working(let working)? = step {
            // The one that may be going in circles: its hint, its turn's
            // time, and a click on the row brings it up.
            let circling = circlingColumn
            return SidebarRowSummary(
                mark: .working,
                status: SidebarStatusLine(
                    text: circling?.circling?.statusText ?? followUp?.roundText ?? "Working", tone: .neutral,
                    detail: circling?.circling?.detail
                ),
                trailing: (circling.map { [$0] } ?? working).compactMap(\.elapsedDisplay).first.map { .turn($0) } ?? age,
                focusColumn: circling?.index
            )
        }
        if case .answered(let answered)? = step {
            return row(.asking, SidebarWorkspaceCardRenderer.answeredText(answered), .neutral)
        }
        // A restored agent that hasn't resumed: selecting the row resumes it
        // too.
        if let paused = columns.first(where: { $0.deferredAgent != nil }), let agent = paused.deferredAgent {
            return SidebarRowSummary(
                mark: .idle,
                status: SidebarStatusLine(
                    text: "Paused · Resume", tone: .neutral,
                    action: .resume(columnIndex: paused.index, columnID: agent.columnID), linkText: "Resume"
                ),
                trailing: age
            )
        }
        if let blocker = blockerText {
            return row(.blocked, "Blocked · \(blocker)", .neutral)
        }
        // A finished turn the user hasn't looked at yet: until then, before
        // the pull request's lasting line. Its own status line says it with
        // a grey check, else "Done".
        if columns.contains(where: { $0.attention == .finished }) {
            return turnStatusLine.map { row(.finished, $0, .neutral) } ?? row(.idle, "Done", .neutral)
        }
        if let pullRequest = prInfo,
           let summary = Self.pullRequestRow(pullRequest, cleanup: mergedCleanup, hasFeedback: prFeedback != nil, age: age) {
            return summary
        }
        if let next = nextStepText {
            return row(.idle, Self.nextStepLine(next), .neutral)
        }
        if let statusLine {
            return row(.idle, statusLine, .neutral)
        }
        let place = gitBranch ?? columns.first(where: \.isFocused)?.abbreviatedCwd ?? columns.first?.abbreviatedCwd
        return row(.idle, place ?? "No activity yet", place == nil ? .neutral : .branch)
    }

    /// What its agents do, the most pressing first: the agents' steps of
    /// `rowSummary`'s ladder, which the Board as stages reads too
    /// (`BoardStages.TaskReading`). Nil when no agent waits, stopped, asks
    /// or works, and no answer waits to be typed.
    enum AgentStep {
        /// A column waits on the user: the row's words after "Needs you · ";
        /// a Mission question come to the user is its own question, which a
        /// click answers.
        case needsYou(ColumnInfo, words: String, isHandedOff: Bool)
        /// A column stopped: "Stopped on an API error".
        case broken(ColumnInfo, sentence: String)
        /// A column asked the agent that started it, which hasn't answered.
        case asking(ColumnInfo, SidebarMissionQuestion)
        case working([ColumnInfo])
        /// An answer to a column's question waits to be typed: no agent
        /// waits or works meanwhile.
        case answered(SidebarMissionQuestion)
    }

    var agentStep: AgentStep? { agentStep(in: columns, includingWait: { _ in true }) }

    func agentStep(in columns: [ColumnInfo], includingWait: (ColumnInfo) -> Bool) -> AgentStep? {
        if let waiting = columns.first(where: { $0.attention == .waiting && includingWait($0) }) {
            if let question = waiting.missionQuestion, question.handOff != nil, !question.isAnswered {
                return .needsYou(waiting, words: question.needsYouDetail, isHandedOff: true)
            }
            return .needsYou(waiting, words: Self.needsYouDetail(waiting), isHandedOff: false)
        }
        if let broken = columns.first(where: { $0.attention == .error }), let headline = broken.attentionSummary?.headline {
            return .broken(broken, sentence: Self.sentence(headline))
        }
        let question = Self.questionColumn(in: columns)
        if let asking = question, let pending = asking.missionQuestion, !pending.isAnswered {
            return .asking(asking, pending)
        }
        let working = columns.filter { $0.agentStatus == .working }
        if !working.isEmpty { return .working(working) }
        return question?.missionQuestion.map(AgentStep.answered)
    }

    /// The working column that may be going in circles, if any.
    var circlingColumn: ColumnInfo? {
        columns.first { $0.agentStatus == .working && $0.circling != nil }
    }

    /// The next step on the status line: "Next · write the import side".
    static func nextStepLine(_ text: String) -> String {
        "Next · \(text)"
    }

    /// The column whose Mission question the status line shows: one still
    /// unanswered first.
    static func questionColumn(in columns: [ColumnInfo]) -> ColumnInfo? {
        columns.first { $0.missionQuestion.map { !$0.isAnswered } ?? false } ?? columns.first { $0.missionQuestion != nil }
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
    /// to merge": checks passed, no conflict (GitHub's "UNKNOWN" while it
    /// recomputes after a push doesn't count, or the line would flicker), no
    /// review asked for or asking for changes, and no feedback waiting to
    /// be dealt with.
    private static func pullRequestRow(
        _ pullRequest: PRInfo, cleanup: MergedCleanupOffer?, hasFeedback: Bool, age: SidebarRowSummary.Trailing?
    ) -> SidebarRowSummary? {
        let number = SidebarRowSummary.Trailing.pullRequest(pullRequest.number)
        func row(_ mark: SidebarRowMark, _ text: String, _ action: SidebarStatusLine.Action?,
                 trailing: SidebarRowSummary.Trailing?, linkText: String? = nil) -> SidebarRowSummary {
            SidebarRowSummary(
                mark: mark, status: SidebarStatusLine(text: text, tone: .neutral, action: action, linkText: linkText),
                trailing: trailing
            )
        }
        switch pullRequest.state {
        case .merged:
            switch cleanup {
            case .available?: return row(.merged, "Merged · Clean up", .cleanUp, trailing: number, linkText: "Clean up")
            case .inProgress?: return row(.merged, "Merged · cleaning up…", nil, trailing: number)
            case nil: return row(.merged, "Merged", nil, trailing: number)
            }
        case .open:
            if pullRequest.isDraft { return row(.idle, "#\(pullRequest.number) · draft", nil, trailing: age) }
            switch pullRequest.ciStatus {
            case "PENDING"?: return row(.checksRunning, "#\(pullRequest.number) · checks running", nil, trailing: age)
            case "SUCCESS"?:
                let reviewBlocks = ["REVIEW_REQUIRED", "CHANGES_REQUESTED"].contains(pullRequest.reviewDecision ?? "")
                guard pullRequest.mergeable != "CONFLICTING", !reviewBlocks, !hasFeedback else {
                    return row(.idle, "#\(pullRequest.number) · checks passed", nil, trailing: age)
                }
                return row(.readyToMerge, "Ready to merge", nil, trailing: number)
            default:
                return row(.idle, "#\(pullRequest.number) · open", nil, trailing: age)
            }
        default:
            return nil
        }
    }
}
