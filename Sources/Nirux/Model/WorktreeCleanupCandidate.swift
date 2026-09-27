import Foundation

/// A worktree in the cleanup flows, with the Nirux side of it: the
/// workspaces open there, which the cleanup closes, and what closing them
/// or deleting the folder would end or lose. Built on the main thread;
/// `inspection` arrives from `WorktreeCleanup.inspect` once git and gh
/// have answered.
struct WorktreeCleanupCandidate: Equatable {
    struct Workspace: Equatable {
        let id: String
        let title: String
    }

    /// The worktree's top level, or the missing folder, as the workspaces
    /// store it.
    let path: String
    /// Open at `path` or below it: closed by the cleanup. Empty for a
    /// worktree no workspace is open in.
    let workspaces: [Workspace]
    /// The agents closing `workspaces` ends.
    var agents: [WorkspaceClosePolicy.LiveAgent]
    /// Agents of other workspaces running inside the folder, e.g.
    /// "Claude in “main”": deleting the folder would pull it from under them.
    var foreignAgents: [String] = []
    /// Titles of the workspaces with an editor holding unsaved changes in
    /// `workspaces`, or to a file in the folder.
    var unsavedEditors: [String]
    var inspection: WorktreeCleanup.Inspection?

    enum Availability: Equatable {
        case checking
        /// Every check passed. Preselected in the bulk list only when no
        /// agent is busy or of unknown status, a workspace is open in it,
        /// and its folder is the one made for its branch.
        case ready(WorktreeCleanup.Plan, preselected: Bool)
        /// The folder is gone: closing the workspaces is all that's left.
        case closeOnly
        case blocked([String])
    }

    var availability: Availability {
        guard let inspection else { return .checking }
        var problems: [String] = []
        if !unsavedEditors.isEmpty {
            problems.append("Unsaved editor changes in \(Self.quotedList(unsavedEditors)).")
        }
        if !foreignAgents.isEmpty {
            problems.append("Running in this folder from another workspace: \(foreignAgents.joined(separator: ", ")).")
        }
        switch inspection {
        case .folderMissing:
            return problems.isEmpty ? .closeOnly : .blocked(problems)
        case .unavailable(let reason):
            return .blocked([reason] + problems)
        case .inspected(let report):
            problems = report.problems + problems
            guard problems.isEmpty, let plan = report.plan else {
                return .blocked(problems.isEmpty ? ["The pull request isn't confirmed merged."] : problems)
            }
            let preselected = agents.allSatisfy { $0.status == .idle }
                && !workspaces.isEmpty
                && plan.worktree.folderMatchesBranch
            return .ready(plan, preselected: preselected)
        }
    }

    var report: WorktreeCleanup.Report? {
        guard case .inspected(let report) = inspection else { return nil }
        return report
    }

    /// "folder · branch" once inspected, else the folder name.
    var title: String {
        guard let worktree = report?.worktree else { return (path as NSString).lastPathComponent }
        return "\(worktree.folderName) · \(worktree.branch ?? "detached HEAD")"
    }

    var workspaceIDs: [String] { workspaces.map(\.id) }

    /// One line under the row's title in the bulk list; a blocked row's
    /// other problems are in its tooltip.
    var detail: String {
        var parts: [String] = []
        switch availability {
        case .checking:
            return "Checking…"
        case .closeOnly:
            parts.append("Folder is gone: only the workspace closes")
        case .blocked(let problems):
            let first = problems.first ?? ""
            if let pullRequest = report?.pullRequest, !first.contains("#\(pullRequest.number) ") {
                parts.append("PR #\(pullRequest.number) \(pullRequest.state.lowercased())")
            }
            parts.append(problems.count > 1 ? "\(first) (+\(problems.count - 1) more)" : first)
        case .ready(let plan, _):
            parts.append("PR #\(plan.pullRequest.number) merged")
            parts.append("clean")
            if !plan.worktree.leftovers.isEmpty {
                parts.append("to the Trash: \(WorktreeCleanup.summarized(plan.worktree.leftovers, limit: 2))")
            }
            if !plan.worktree.folderMatchesBranch { parts.append("folder named for another branch") }
            if workspaces.isEmpty { parts.append("not open in Nirux") }
        }
        if !agents.isEmpty {
            parts.append(agents.map { "\($0.displayName) \($0.statusDescription)" }.joined(separator: ", "))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Confirmation text

    /// What the single-worktree confirmation lists: exactly what goes.
    func confirmationLines(for plan: WorktreeCleanup.Plan) -> [String] {
        var lines = ["Pull request #\(plan.pullRequest.number) is merged. This:"]
        lines.append("• deletes the folder \(plan.worktree.path.abbreviatedPath(maxComponents: .max))")
        lines.append("• deletes the local branch \(plan.branch)")
        if !plan.worktree.leftovers.isEmpty {
            lines.append(
                "• moves to the Trash, in “\(plan.worktree.folderName) leftovers”: "
                    + plan.worktree.leftovers.joined(separator: ", ")
            )
        }
        if !plan.worktree.buildOutput.isEmpty {
            lines.append("• deletes its build output: \(plan.worktree.buildOutputSummary.joined(separator: ", "))")
        }
        if let workspacePhrase { lines.append("• closes \(workspacePhrase)") }
        if !plan.worktree.folderMatchesBranch {
            lines.append(
                "The folder isn’t named for \(plan.branch): it may be a base reused across branches, "
                    + "with plans of its own."
            )
        }
        if !agents.isEmpty {
            lines.append(WorkspaceClosePolicy.agentDetail(agents, closing: closingTarget))
        }
        lines.append("The remote branch is not touched.")
        return lines
    }

    /// The close-only confirmation, for a folder that's already gone.
    func closeOnlyLines() -> [String] {
        var lines = [
            "\(path.abbreviatedPath(maxComponents: .max)) no longer exists: nothing is deleted. "
                + "Closing \(workspacePhrase ?? "its workspace") is all that's left."
        ]
        if !agents.isEmpty {
            lines.append(WorkspaceClosePolicy.agentDetail(agents, closing: closingTarget))
        }
        return lines
    }

    /// The bulk confirmation's recap of the checked candidates, in full.
    static func summaryLines(for selected: [WorktreeCleanupCandidate]) -> [String] {
        var lines: [String] = []
        var agentLines: [String] = []
        for candidate in selected {
            switch candidate.availability {
            case .ready(let plan, _):
                lines.append("• \(candidate.title), PR #\(plan.pullRequest.number): folder and branch \(plan.branch)")
                if !plan.worktree.leftovers.isEmpty {
                    lines.append("    to the Trash: \(plan.worktree.leftovers.joined(separator: ", "))")
                }
                if !plan.worktree.buildOutput.isEmpty {
                    lines.append("    build output deleted: \(plan.worktree.buildOutputSummary.joined(separator: ", "))")
                }
                if !plan.worktree.folderMatchesBranch {
                    lines.append("    the folder isn’t named for \(plan.branch)")
                }
            case .closeOnly:
                lines.append("• \(candidate.title): folder already gone, workspace closes")
            case .checking, .blocked:
                continue
            }
            if !candidate.agents.isEmpty {
                let agents = candidate.agents.map { "\($0.displayName) \($0.statusDescription)" }
                agentLines.append("• \(agents.joined(separator: ", ")) in \(quotedList(candidate.workspaces.map(\.title)))")
            }
        }
        if !agentLines.isEmpty {
            lines.append("")
            lines.append("Closing their workspaces ends these agent sessions:")
            lines += agentLines
        }
        lines.append("")
        lines.append("Leftovers go to the Trash, one folder per worktree. Remote branches are not touched.")
        return lines
    }

    private var closingTarget: String { workspaces.count > 1 ? "workspaces" : "workspace" }

    private var workspacePhrase: String? {
        let titles = workspaces.map(\.title)
        switch titles.count {
        case 0: return nil
        case 1: return "the workspace “\(titles[0])”"
        default: return "the workspaces \(Self.quotedList(titles))"
        }
    }

    static func quotedList(_ titles: [String]) -> String {
        titles.map { "“\($0)”" }.joined(separator: ", ")
    }
}
