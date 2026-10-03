import Foundation

// MARK: - Execution

extension WorktreeCleanup {
    enum Execution: Equatable, Sendable {
        /// Folder and branch gone. `trashFolder`: the Trash folder holding
        /// the leftovers, if there were any.
        case cleaned(forcedBranchDelete: Bool, trashFolder: String?)
        /// The folder is gone but the branch was kept: why, with git's output.
        case branchKept(String, trashFolder: String?)
        /// Stopped with the worktree still registered, or with only part of
        /// its folder removed by a failed `git worktree remove`: why, with
        /// git's output.
        case failed(String)
    }

    /// Deletes the worktree and its branch as `plan` describes them. The
    /// worktree is read again first: an agent may have committed or written
    /// files since the check, and anything new stops it. The leftovers go
    /// to the Trash, then `git worktree remove` runs without `--force`, so
    /// git checks the folder once more itself. Stops at the first failure.
    /// Once the branch is deleted, so is its Branch Review file, in every
    /// project; a kept branch keeps it.
    static func execute(_ plan: Plan, tools: Tools = .installed) -> Execution {
        guard case .worktree(let current) = readWorktree(at: plan.worktree.path, tools: tools) else {
            return .failed("\(plan.worktree.path) can no longer be read. Nothing was deleted.")
        }
        let changed = changesSinceCheck(plan, current: current)
        guard changed.isEmpty else {
            return .failed(
                (["The worktree changed since it was checked. Nothing was deleted."] + changed)
                    .joined(separator: "\n")
            )
        }

        let trashed: TrashedLeftovers?
        do {
            trashed = try moveToTrash(current.leftovers, from: current.path, tools: tools)
        } catch {
            return .failed("Couldn't move the leftovers to the Trash: \(error.localizedDescription) Nothing else was touched.")
        }
        let trashFolder = trashed?.folder.lastPathComponent

        let removal = git(["worktree", "remove", current.path], in: current.mainCheckout, tools: tools, timeout: tools.writeTimeout)
        guard removal.status == 0 else {
            return removalFailure(removal, worktree: current, trashed: trashed, tools: tools)
        }

        func cleaned(forcedBranchDelete: Bool) -> Execution {
            if let stateDirectory = tools.reviewStateDirectory {
                BranchReview.Store.deleteReviews(
                    branch: plan.branch, repository: current.commonDirectory, stateDirectory: stateDirectory
                )
            }
            return .cleaned(forcedBranchDelete: forcedBranchDelete, trashFolder: trashFolder)
        }

        let softDelete = git(["branch", "-d", "--", plan.branch], in: current.mainCheckout, tools: tools, timeout: tools.writeTimeout)
        if softDelete.status == 0 { return cleaned(forcedBranchDelete: false) }
        // A squash merge leaves the branch unmerged as far as git knows. The
        // pull request is MERGED and contains the tip, which must not have
        // moved since.
        let tipNow = git(["rev-parse", "-q", "--verify", "refs/heads/\(plan.branch)"], in: current.mainCheckout, tools: tools)
        guard tipNow.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == plan.tip else {
            return .branchKept(
                "The worktree folder was removed, but \(plan.branch) moved since it was checked, "
                    + "so the branch was kept.\n\(output(of: softDelete))",
                trashFolder: trashFolder
            )
        }
        let forcedDelete = git(["branch", "-D", "--", plan.branch], in: current.mainCheckout, tools: tools, timeout: tools.writeTimeout)
        guard forcedDelete.status == 0 else {
            return .branchKept(
                "The worktree folder was removed, but deleting \(plan.branch) failed:\n\(output(of: forcedDelete))",
                trashFolder: trashFolder
            )
        }
        return cleaned(forcedBranchDelete: true)
    }

    /// What differs from the checked `plan`, as reasons to stop.
    static func changesSinceCheck(_ plan: Plan, current: Worktree) -> [String] {
        var changed = localProblems(current)
        if current.branch != plan.branch || current.tip != plan.tip {
            changed.append("\(plan.branch) moved since it was checked.")
        }
        if current.mainCheckout != plan.worktree.mainCheckout {
            changed.append("Its main checkout is no longer \(plan.worktree.mainCheckout).")
        }
        // New build output (a Finder .DS_Store, say) is deleted like the rest.
        let confirmed = Set(plan.worktree.leftovers)
        let appeared = current.leftovers.filter { !confirmed.contains($0) }
        if !appeared.isEmpty {
            changed.append("New files appeared: \(appeared.joined(separator: ", ")).")
        }
        return changed
    }

    /// git refused before touching anything (the folder is there and still
    /// listed): the leftovers go back. Otherwise it deleted part of it, the
    /// folder or its entry: the leftovers stay in the Trash, and the report
    /// says what's left.
    private static func removalFailure(
        _ removal: GitResult, worktree: Worktree, trashed: TrashedLeftovers?, tools: Tools
    ) -> Execution {
        let gitOutput = "git worktree remove failed:\n\(output(of: removal))"
        let folderExists = FileManager.default.fileExists(atPath: worktree.path)
        let stillListed = worktreeListing(in: worktree.mainCheckout, tools: tools)?
            .contains { ($0.path.realPath ?? URL(fileURLWithPath: $0.path).standardizedFileURL.path) == worktree.path }
            ?? true
        guard folderExists, stillListed else {
            let folder = folderExists
                ? "Part of \(worktree.path) is left: delete it yourself."
                : "\(worktree.path) was deleted."
            let entry = stillListed
                ? "git still lists the worktree (git worktree prune clears it)."
                : "git no longer tracks it."
            let trashNote = trashed.map { " Its leftovers are in the Trash, in “\($0.folder.lastPathComponent)”." } ?? ""
            return .failed(
                "\(gitOutput)\n\(folder) \(entry) The branch \(worktree.branch ?? "") was kept.\(trashNote)"
            )
        }
        guard let trashed else { return .failed(gitOutput) }
        let stuck = putBack(trashed, into: worktree.path)
        guard stuck.isEmpty else {
            return .failed(
                "\(gitOutput)\nThese leftovers couldn't be put back and are in the Trash, "
                    + "in “\(trashed.folder.lastPathComponent)”: \(stuck.joined(separator: ", "))."
            )
        }
        return .failed("\(gitOutput)\nThe worktree is still there, leftovers included.")
    }

    // MARK: - Trash

    struct TrashedLeftovers {
        /// The folder in the Trash: "<worktree folder> leftovers".
        let folder: URL
        /// What it holds, relative to it and to the worktree.
        let relativePaths: [String]
    }

    private struct LeftoverError: LocalizedError {
        let errorDescription: String?
    }

    /// Moves `relativePaths` out of the worktree into one folder, then that
    /// folder to the Trash, so `git worktree remove` can't take them and
    /// the user can get them back. Nil when there's nothing to move. On
    /// failure, whatever moved is put back; what can't be stays in the
    /// staging folder, which the error names.
    static func moveToTrash(_ relativePaths: [String], from worktree: String, tools: Tools) throws -> TrashedLeftovers? {
        guard !relativePaths.isEmpty else { return nil }
        let fileManager = FileManager.default
        let root = URL(fileURLWithPath: worktree, isDirectory: true)
        // On the worktree's volume, so every move is a rename.
        let staging = try fileManager.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: root, create: true
        )
        let bundle = staging.appendingPathComponent("\(root.lastPathComponent) leftovers", isDirectory: true)
        var moved: [String] = []
        do {
            for entry in relativePaths {
                let relative = entry.hasSuffix("/") ? String(entry.dropLast()) : entry
                let source = root.appendingPathComponent(relative)
                // Its folder must be the worktree's own: a symlink could
                // lead the move somewhere else.
                guard let parent = source.deletingLastPathComponent().path.realPath,
                      parent == worktree || parent.hasPrefix(worktree + "/")
                else {
                    throw LeftoverError(errorDescription: "\(relative) is not inside the worktree.")
                }
                let target = bundle.appendingPathComponent(relative)
                try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.moveItem(at: source, to: target)
                moved.append(relative)
            }
            let trashedFolder = try tools.trash(bundle)
            try? fileManager.removeItem(at: staging)
            return TrashedLeftovers(folder: trashedFolder, relativePaths: moved)
        } catch {
            let stuck = putBack(TrashedLeftovers(folder: bundle, relativePaths: moved), into: worktree)
            guard stuck.isEmpty else {
                throw LeftoverError(errorDescription:
                    "\(error.localizedDescription) \(stuck.joined(separator: ", ")) couldn't be put back "
                        + "and \(stuck.count == 1 ? "is" : "are") in \(bundle.path).")
            }
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    /// Moves the leftovers back into the worktree; returns those that
    /// couldn't be. The emptied folder is deleted.
    static func putBack(_ trashed: TrashedLeftovers, into worktree: String) -> [String] {
        let fileManager = FileManager.default
        let root = URL(fileURLWithPath: worktree, isDirectory: true)
        var stuck: [String] = []
        for relative in trashed.relativePaths {
            let target = root.appendingPathComponent(relative)
            do {
                try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.moveItem(at: trashed.folder.appendingPathComponent(relative), to: target)
            } catch {
                stuck.append(relative)
            }
        }
        if stuck.isEmpty { try? fileManager.removeItem(at: trashed.folder) }
        return stuck
    }
}
