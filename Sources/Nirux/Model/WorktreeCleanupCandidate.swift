import Foundation

/// A worktree in the cleanup flows, with the Nirux side of it: the
/// workspaces open there, which the cleanup closes, and what closing them
/// would end or lose. Built on the main thread; `inspection` arrives from
/// `WorktreeCleanup.inspect` once git and gh have answered.
struct WorktreeCleanupCandidate: Equatable {
    struct Workspace: Equatable {
        let id: String
        let title: String
    }

    /// The worktree's top level, or the missing folder, as the workspaces
    /// store it.
    let path: String
    let workspaces: [Workspace]
    var agents: [WorkspaceClosePolicy.LiveAgent]
    /// Titles of the workspaces with an editor holding unsaved changes.
    var unsavedEditors: [String]
    var inspection: WorktreeCleanup.Inspection?

    enum Availability: Equatable {
        case checking
        /// Every check passed. Not preselected in the bulk list when an
        /// agent is busy, or its status can't be trusted.
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
            return .ready(plan, preselected: agents.allSatisfy { $0.status == .idle })
        }
    }

    var report: WorktreeCleanup.Report? {
        guard case .inspected(let report) = inspection else { return nil }
        return report
    }

    /// "repo · branch" once inspected, else the folder name.
    var title: String {
        guard let worktree = report?.worktree else { return (path as NSString).lastPathComponent }
        return "\(worktree.repositoryName) · \(worktree.branch ?? "detached HEAD")"
    }

    var workspaceIDs: [String] { workspaces.map(\.id) }

    /// One line under the row's title in the bulk list; a blocked row's
    /// other problems are in its tooltip.
    var detail: String {
        var parts: [String] = []
        let pullRequest = report?.pullRequest.map { "PR #\($0.number) \($0.state.lowercased())" }
        switch availability {
        case .checking:
            return "Checking…"
        case .closeOnly:
            parts.append("Folder is gone: only the workspace closes")
        case .blocked(let problems):
            let first = problems.first ?? ""
            if let pullRequest, let number = report?.pullRequest?.number, !first.contains("#\(number) ") {
                parts.append(pullRequest)
            }
            parts.append(problems.count > 1 ? "\(first) (+\(problems.count - 1) more)" : first)
        case .ready(let plan, _):
            parts.append("PR #\(plan.pullRequest.number) merged")
            parts.append("clean")
            if !plan.worktree.disposableFiles.isEmpty { parts.append("handover files") }
            if !plan.worktree.ignoredEntries.isEmpty {
                parts.append("ignored: \(WorktreeCleanup.summarized(plan.worktree.ignoredEntries, limit: 2))")
            }
        }
        if !agents.isEmpty {
            parts.append(agents.map { "\($0.displayName) \($0.statusDescription)" }.joined(separator: ", "))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Confirmation text

    /// What the single-worktree confirmation lists: exactly what goes.
    func confirmationLines(for plan: WorktreeCleanup.Plan) -> [String] {
        var lines = ["Pull request #\(plan.pullRequest.number) is merged. This deletes:"]
        lines.append("• the folder \(plan.worktree.path.abbreviatedPath(maxComponents: .max))")
        lines.append("• the local branch \(plan.branch)")
        if !plan.worktree.disposableFiles.isEmpty {
            lines.append("• handover files: \(plan.worktree.disposableFiles.joined(separator: ", "))")
        }
        if !plan.worktree.ignoredEntries.isEmpty {
            lines.append("• ignored files in the folder: \(WorktreeCleanup.summarized(plan.worktree.ignoredEntries, limit: 8))")
        }
        lines.append("and closes \(workspacePhrase).")
        if !agents.isEmpty {
            lines.append(WorkspaceClosePolicy.agentDetail(agents, closing: "workspace"))
        }
        lines.append("The remote branch is not touched.")
        return lines
    }

    /// The close-only confirmation, for a folder that's already gone.
    func closeOnlyLines() -> [String] {
        var lines = [
            "\(path.abbreviatedPath(maxComponents: .max)) no longer exists: there is nothing left on disk "
                + "to clean up. Closing \(workspacePhrase) is all that's left."
        ]
        if !agents.isEmpty {
            lines.append(WorkspaceClosePolicy.agentDetail(agents, closing: "workspace"))
        }
        return lines
    }

    /// The bulk confirmation's recap of the checked candidates.
    static func summaryLines(for selected: [WorktreeCleanupCandidate]) -> [String] {
        var lines: [String] = []
        var agentLines: [String] = []
        for candidate in selected {
            switch candidate.availability {
            case .ready(let plan, _):
                var deleted = ["folder", "branch \(plan.branch)"]
                if !plan.worktree.disposableFiles.isEmpty { deleted.append("handover files") }
                if !plan.worktree.ignoredEntries.isEmpty {
                    deleted.append("ignored \(WorktreeCleanup.summarized(plan.worktree.ignoredEntries, limit: 3))")
                }
                lines.append("• \(candidate.title), PR #\(plan.pullRequest.number): \(deleted.joined(separator: ", "))")
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
        lines.append("Every workspace open in these folders closes. Remote branches are not touched.")
        return lines
    }

    private var workspacePhrase: String {
        let titles = workspaces.map(\.title)
        return titles.count == 1 ? "the workspace “\(titles[0])”" : "the workspaces \(Self.quotedList(titles))"
    }

    static func quotedList(_ titles: [String]) -> String {
        titles.map { "“\($0)”" }.joined(separator: ", ")
    }
}
