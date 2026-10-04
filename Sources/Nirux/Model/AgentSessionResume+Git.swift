import Foundation

// MARK: - The disk and git, for a Resume

extension AgentSessionResume.Probe {
    /// The real disk and git, read-only: nothing changes in the repository
    /// until the Resume goes ahead (`recreateWorktree`). Runs git, so call
    /// `plan` with it off the main thread.
    static func onDisk() -> Self {
        Self(
            directoryExists: { path in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
            },
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            currentBranch: { GitWorktree.currentBranch(at: $0) },
            worktrees: { GitWorktree.list(repoRoot: $0, timeout: AgentSessionResume.probeTimeout) },
            hasBranch: { mainCheckout, branch in
                AgentSessionResume.isValidBranchName(branch)
                    && AgentSessionResume.gitSucceeds(
                        ["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)^{commit}"], in: mainCheckout
                    )
            },
            hasCommit: { mainCheckout, commit in
                commit.range(of: "^[0-9a-f]{7,64}$", options: .regularExpression) != nil
                    && AgentSessionResume.gitSucceeds(["cat-file", "-e", "\(commit)^{commit}"], in: mainCheckout)
            }
        )
    }
}

extension AgentSessionResume {
    /// A read is instant; past this, git is stuck and the worktree isn't
    /// offered.
    static let probeTimeout: TimeInterval = 10

    static func isValidBranchName(_ branch: String) -> Bool {
        !branch.isEmpty && !branch.hasPrefix("-")
    }

    static func gitSucceeds(_ arguments: [String], in directory: String) -> Bool {
        GitWorktree.gitRunFull(
            arguments, cwd: directory, timeout: probeTimeout, environment: GitDetect.readOnlyEnvironment
        ).status == 0
    }

    /// What `recreateWorktree` did.
    enum Recreation: Equatable {
        case done
        /// The folder was there before git ran: it appeared after the plan.
        case alreadyBack
        case failed(String)
    }

    /// Brings a removed worktree back at `path` (see `Plan.Place`): a
    /// branch is checked out, a commit detached. Two at once on one path
    /// break each other inside git: run them one after the other (see
    /// `SessionResumeState.queue`).
    ///
    /// Never `git worktree prune`: it would drop the entry of every
    /// worktree whose folder is missing, one moved in the Finder or on a
    /// disk that isn't mounted included, and break it. When git still
    /// lists `path`, `--force` replaces that one entry; it still refuses a
    /// folder that isn't empty. It would also check out a branch another
    /// worktree has, so that is checked first.
    static func recreateWorktree(at path: String, ref: String, mainCheckout: String) -> Recreation {
        guard path.hasPrefix("/") else { return .failed("\(path) isn't an absolute path") }
        guard !ref.hasPrefix("-") else { return .failed("\(ref) isn't a branch or a commit") }
        guard !FileManager.default.fileExists(atPath: path) else { return .alreadyBack }
        let worktrees = GitWorktree.list(repoRoot: mainCheckout, timeout: probeTimeout)
        let registered = worktrees.first { isSamePath($0.path, path) }
        if registered?.isLocked == true { return .failed("git keeps \(path) locked (git worktree unlock)") }
        if let holder = worktrees.first(where: { $0.branch == ref && !isSamePath($0.path, path) }) {
            return .failed("\(ref) is checked out in \(holder.path)")
        }
        let force = registered == nil ? [] : ["--force"]
        // --quiet: no "Preparing worktree" line ahead of an error.
        let result = GitWorktree.gitRunFull(["worktree", "add", "--quiet"] + force + ["--", path, ref], cwd: mainCheckout)
        guard result.status != 0 else { return .done }
        let error = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return .failed(error.isEmpty ? "git worktree add failed" : error)
    }

    /// Two agents appending to one transcript corrupt it. A Claude session
    /// whose transcript changed well after Nirux last saw it, and lately,
    /// runs somewhere else: in another app, or in another Nirux on the same
    /// state.
    static func transcriptChangedElsewhere(_ record: AgentSessionRecord, now: TimeInterval) -> String? {
        guard record.agent == .claude, let transcriptPath = record.transcriptPath,
              let modified = (try? FileManager.default.attributesOfItem(atPath: transcriptPath))?[.modificationDate] as? Date
        else { return nil }
        let changedAt = modified.timeIntervalSince1970
        // A turn writes without a hook Nirux follows until it ends; a column
        // closed mid-turn ended the session then.
        let lastSeen = max(record.lastActivityAt, record.endedAt ?? 0)
        guard changedAt > lastSeen + elsewhereSlack, now - changedAt < elsewhereWindow else { return nil }
        return "Its transcript changed \(SessionHistory.ago(now - changedAt)), after Nirux last saw it: the session "
            + "may be running somewhere else. Two agents writing to one session corrupt it."
    }

    /// Claude may still write a line or two after its turn ends.
    static let elsewhereSlack: TimeInterval = 60
    static let elsewhereWindow: TimeInterval = 600
}
