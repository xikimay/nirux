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
    /// to the Trash, git writes the committed version of the tracked
    /// disposable files back, then `git worktree remove` runs without
    /// `--force`, so git checks the folder once more itself. Stops at the
    /// first failure. Once the branch is deleted, so is its Branch Review
    /// file; a kept branch keeps it.
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

        // A committed one deleted since the check is written back too: the
        // commit holds it, nothing is lost.
        let restored = current.restoredFiles
        var restore = Restore(files: restored, missingFolders: missingFolders(of: restored, in: current.path))
        if !restored.isEmpty {
            // Plumbing: no hook runs, and the index is left alone. It never
            // writes over a file, so a failure midway is put back like the
            // rest: no write timeout.
            let checkout = git(["rev-parse", "HEAD"], in: current.path, tools: tools)
            guard checkout.status == 0 else {
                return putBackAfterFailure(
                    "git couldn't write back the committed \(summarized(restored)):\n\(output(of: checkout))\nNothing was deleted.",
                    worktree: current, restore: restore, trashed: trashed, tools: tools
                )
            }
            restore.written = Dictionary(uniqueKeysWithValues: restored.compactMap { path in
                FileStamp(of: current.path + "/" + path).map { (path, $0) }
            })
            restore.wroteAll = true
        }

        let removal = git(["worktree", "remove", current.path], in: current.mainCheckout, tools: tools, timeout: tools.writeTimeout)
        guard removal.status == 0 else {
            return removalFailure(removal, worktree: current, restore: restore, trashed: trashed, tools: tools)
        }

        func cleaned(forcedBranchDelete: Bool) -> Execution {
            if let stateDirectory = tools.reviewStateDirectory {
                BranchReview.Store(
                    repository: current.commonDirectory, branch: plan.branch, stateDirectory: stateDirectory
                )?.delete()
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
            changed.append("New files to move to the Trash: \(appeared.joined(separator: ", ")).")
        }
        return changed
    }

    /// git refused before touching anything (the folder is there and still
    /// listed): the leftovers go back. Otherwise it deleted part of it, the
    /// folder or its entry: the leftovers stay in the Trash, and the report
    /// says what's left.
    private static func removalFailure(
        _ removal: GitResult, worktree: Worktree, restore: Restore, trashed: TrashedLeftovers?, tools: Tools
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
        return putBackAfterFailure(
            gitOutput, worktree: worktree, restore: restore, trashed: trashed, tools: tools,
            done: "The worktree is still there, leftovers included."
        )
    }

    /// The committed files `checkout-index` writes back, and the folders
    /// it would create for them.
    struct Restore {
        let files: [String]
        /// Deepest first.
        let missingFolders: [String]
        /// `checkout-index` succeeded: every file there is its copy.
        var wroteAll = false
        /// The files as `lstat` found them right after it.
        var written: [String: FileStamp] = [:]
    }

    /// A regular file as `lstat` sees it: the same stamp later, it is the
    /// same file, untouched.
    struct FileStamp: Equatable {
        let device: Int64
        let inode: UInt64
        let size: Int64
        let modified: [Int]
        let changed: [Int]

        init?(of path: String) {
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
            device = Int64(info.st_dev)
            inode = UInt64(info.st_ino)
            size = Int64(info.st_size)
            modified = [Int(info.st_mtimespec.tv_sec), info.st_mtimespec.tv_nsec]
            changed = [Int(info.st_ctimespec.tv_sec), info.st_ctimespec.tv_nsec]
        }
    }

    /// The folders, relative to `worktree`, missing on the way to `files`.
    static func missingFolders(of files: [String], in worktree: String) -> [String] {
        var missing: Set<String> = []
        for file in files {
            var folder = (file as NSString).deletingLastPathComponent
            while !folder.isEmpty, !FileManager.default.fileExists(atPath: worktree + "/" + folder) {
                missing.insert(folder)
                folder = (folder as NSString).deletingLastPathComponent
            }
        }
        return missing.sorted { $0.count > $1.count }
    }

    /// Stopped with the folder whole: what git wrote back makes way for the
    /// leftovers, which go back from the Trash.
    private static func putBackAfterFailure(
        _ reason: String, worktree: Worktree, restore: Restore, trashed: TrashedLeftovers?, tools: Tools,
        done: String? = nil
    ) -> Execution {
        undoRestore(restore, in: worktree.path, tools: tools)
        guard let trashed else { return .failed(reason) }
        let stuck = putBack(trashed, into: worktree.path)
        guard stuck.isEmpty else {
            return .failed(
                "\(reason)\nThese leftovers couldn't be put back and are in the Trash, "
                    + "in “\(trashed.folder.lastPathComponent)”: \(stuck.joined(separator: ", "))."
            )
        }
        return .failed([reason, done].compactMap { $0 }.joined(separator: "\n"))
    }

    /// Deletes the files `checkout-index` wrote back, never one changed
    /// since, then the folders it created, if empty. After a failed
    /// `checkout-index`, a file there may be someone else's: only one
    /// holding the index's version goes.
    private static func undoRestore(_ restore: Restore, in worktree: String, tools: Tools) {
        for path in restore.files {
            let file = URL(fileURLWithPath: worktree).appendingPathComponent(path)
            guard isInside(file.deletingLastPathComponent(), worktree: worktree),
                  let now = FileStamp(of: file.path)
            else { continue }
            let isGitsCopy = restore.wroteAll
                ? now == restore.written[path]
                : matchesIndex(path, in: worktree, tools: tools)
            if isGitsCopy && false { unlink(file.path) }
        }
        for folder in restore.missingFolders {
            let url = URL(fileURLWithPath: worktree).appendingPathComponent(folder)
            if isInside(url.deletingLastPathComponent(), worktree: worktree) { rmdir(url.path) }
        }
    }

    /// Whether the file at `path` is the index's: the blob git makes of it,
    /// filters and line endings applied, is the one the index holds. Not
    /// `git diff --quiet`: some git versions (CI's) take a file just
    /// written, whose stat the index doesn't know, for a changed one, and a
    /// configured external diff tool answers for it.
    private static func matchesIndex(_ path: String, in worktree: String, tools: Tools) -> Bool {
        let file = git(["hash-object", "--", path], in: worktree, tools: tools)
        let indexed = git(["rev-parse", "--verify", "-q", ":" + path], in: worktree, tools: tools)
        let blob = file.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return file.status == 0 && indexed.status == 0 && !blob.isEmpty
            && blob == indexed.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether `folder` resolves to `worktree` or a folder in it: a symlink
    /// could lead a move or a deletion somewhere else.
    private static func isInside(_ folder: URL, worktree: String) -> Bool {
        guard let resolved = folder.path.realPath else { return false }
        return resolved == worktree || resolved.hasPrefix(worktree + "/")
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
                guard isInside(source.deletingLastPathComponent(), worktree: worktree) else {
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
