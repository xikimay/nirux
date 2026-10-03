import Foundation

/// The data behind the Branch Review column (docs/branch-review.md): what a
/// branch changes, from the merge base with its base branch to the working
/// tree, read without writing to the repository (section 7). No UI here.
/// Everything runs git or gh: call it off the main thread, or through
/// `loadSnapshot`.
enum BranchReview {
    enum FileStatus: String, Codable, Equatable, Sendable {
        case added
        case modified
        case deleted
        case renamed
        /// A file became a symlink or a submodule, or the other way round.
        case typeChanged
    }

    struct Line: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case context
            case added
            case removed
            /// "\ No newline at end of file", after the line it is about.
            case noNewlineMarker
        }

        let kind: Kind
        /// Decoded lossily.
        let text: String
        /// The line's bytes, kept only when `text` isn't them (not UTF-8).
        var bytes: Data?
    }

    struct Hunk: Equatable, Sendable {
        let oldStart: Int
        let oldCount: Int
        let newStart: Int
        let newCount: Int
        /// What follows the second "@@": the enclosing function, as git's
        /// funcname rules find it. Left out of the patch hash.
        let section: String
        var lines: [Line]
    }

    /// Why a file's hunks aren't in the snapshot. Its hash and line
    /// counts stay, except for `.notRead`.
    enum Omission: Equatable, Sendable {
        /// Its patch is over `Options.maxFileDiffBytes`: the page shows a
        /// placeholder, as the editor's stacked diff does.
        case tooLarge
        /// The file is folded (`FileChange.fold`), or the unfolded files'
        /// patches add up to more than `Options.maxInlineDiffBytes`: the
        /// page loads it with `filePatch` when its row opens.
        case onDemand
        /// Not read: the diff is over `Options.maxDiffBytes` (the files
        /// with the most changed lines are left out first), git didn't
        /// produce it in time, or it is an untracked file past the read
        /// limits. Only its path and line counts are known, and it has no
        /// hash until `filePatch` loads it: a Reviewed mark must not be
        /// cleared for lack of one.
        case notRead
    }

    /// Why the page folds a file (section 2): its group is collapsed,
    /// counted, never hidden. In the order the folded groups are listed;
    /// the first that applies wins.
    enum Fold: String, CaseIterable, Equatable, Sendable {
        case lockfile
        /// By its name (`*.bundle.js`, `*.min.js`), `linguist-generated` in
        /// `.gitattributes` (unless the branch changes one), or a marker in
        /// its first lines (only when its patch is read).
        case generated
        /// Renamed with no line or mode changed.
        case pureRename
        /// Every hunk reads the same without its blank lines and the
        /// whitespace around its lines: around, not inside; and only at
        /// their end, blank lines kept, where indentation carries meaning
        /// (Python, YAML, shell scripts). See `WhitespaceCheck`.
        case whitespaceOnly
        case binary
    }

    /// The risk signals of section 5, in the order the page lists them.
    enum RiskKind: String, CaseIterable, Equatable, Sendable {
        case persistence
        case security
        case concurrency
        case launch
        case ci
        case sideEffects
        case dependencies
    }

    /// One kind of risk a file raises, and where.
    struct RiskSignal: Equatable, Sendable {
        let kind: RiskKind
        /// What raised it, as the page names it: "@MainActor",
        /// "*Store.swift", "named in .github/workflows/nightly.yml".
        var reasons: [String]
        /// The hunks whose `+` or `-` lines raised it, by index in the
        /// file's patch (as `filePatch` reads it), even when the snapshot
        /// left the hunks out. A `.tooLarge` file's are never shown: the
        /// signal stands for the file.
        var hunks: [Int]
        /// Raised by the file's path: the whole file.
        var byPath: Bool
    }

    struct FileChange: Equatable, Sendable {
        /// Relative to the worktree's top level. The old path for a deletion.
        var path: String
        /// The path before a rename.
        var oldPath: String?
        var status: FileStatus
        /// Set only when the patch states it: the added file's mode, the
        /// deleted file's, or both sides of a mode or type change.
        var oldMode: String?
        var newMode: String?
        /// Rename similarity, in percent.
        var similarity: Int?
        var isBinary = false
        /// Pre- and post-image object ids, kept for binary files only: they
        /// stand in for the lines in the patch hash.
        var oldObjectID: String?
        var newObjectID: String?
        var additions = 0
        var deletions = 0
        /// The size of its patch, header included; 0 when not read.
        var patchBytes = 0
        /// Not tracked by git: read through a temporary index, as git will
        /// show it once added (an addition, or a rename of a deleted file).
        var isUntracked = false
        /// Part of what isn't committed yet (untracked, or `git status`
        /// lists it): the page's "not committed" group.
        var isUncommitted = false
        /// See `patchHash(of:)`. Nil only for `.notRead`.
        var patchHash: String?
        /// Empty when `omission` says why.
        var hunks: [Hunk] = []
        var omission: Omission?
        /// Set when the page folds it; a folded file raises no signal from
        /// its lines.
        var fold: Fold?
        /// In `RiskKind` order. Lines are read only for a file the diff
        /// read (`omission` isn't `.notRead`): "not read" isn't "no risk".
        /// A doc raises no line signal; a test only concurrency.
        var signals: [RiskSignal] = []
        /// What a Swift code file declares on its added lines (section 5,
        /// "Tests against code"). Nil for the other files, a folded one, a
        /// symlink, a deletion, or a change that adds no line.
        var symbols: SymbolScan?
    }

    struct Commit: Equatable, Sendable {
        let oid: String
        let parents: [String]
        let subject: String
        let body: String
        /// A merge that brought in the base branch ("1 merge from main"):
        /// one of its other parents is outside the reviewed range.
        let isMergeFromBase: Bool
    }

    struct Base: Equatable, Sendable {
        /// The base branch, as the header shows it: "main".
        let name: String
        /// What was merged with HEAD: "refs/remotes/origin/main".
        let ref: String
        let mergeBase: String
    }

    enum HeadComparison: Equatable, Sendable {
        /// `ahead`: commits only HEAD has (unpushed); `behind`: commits only
        /// the other side has.
        case counted(ahead: Int, behind: Int)
        /// The other commit isn't in the local repository: it has commits
        /// the worktree doesn't (the merge queue updated the branch on
        /// GitHub, say).
        case notLocal
    }

    struct PullRequest: Equatable, Sendable {
        let number: Int
        let title: String
        let body: String
        let url: String
        let baseRefName: String
        let headRefOid: String
        let isDraft: Bool
    }

    /// What a snapshot found for its branch, for the next one to reuse
    /// (`Options.knownPullRequest`).
    struct KnownPullRequest: Equatable, Sendable {
        let branch: String
        let lookup: PullRequestLookup
    }

    enum PullRequestLookup: Equatable, Sendable {
        case found(PullRequest)
        /// No open pull request for the branch, or none that is its own.
        case notFound
        /// gh is missing, logged out or failed, or the branch has no
        /// GitHub remote: the page works without it and says why.
        case unavailable(String)

        var pullRequest: PullRequest? {
            if case .found(let pullRequest) = self { return pullRequest }
            return nil
        }
    }

    struct Snapshot: Equatable, Sendable {
        /// The worktree's top level.
        let root: String
        let branch: String
        let head: String
        let base: Base
        let pullRequest: PullRequestLookup
        /// Why fetching the base branch failed, when it was asked for.
        let fetchProblem: String?
        /// HEAD against its upstream; nil without one.
        let upstream: HeadComparison?
        /// HEAD against the pull request's head on GitHub; nil without a
        /// pull request.
        let pullRequestHead: HeadComparison?
        /// Something isn't committed: a change `git status` lists, or an
        /// untracked file other than the disposable ones.
        let hasUncommittedChanges: Bool
        /// From the merge base to HEAD, newest first.
        let commits: [Commit]
        /// Sorted by path, one entry per path.
        let files: [FileChange]
        let testsAgainstCode: TestsAgainstCode

        var knownPullRequest: KnownPullRequest { KnownPullRequest(branch: branch, lookup: pullRequest) }

        /// Whether the base is the pull request's base branch. False when
        /// it couldn't be used (never fetched, say): the merge base is then
        /// with the default branch.
        var usesPullRequestBase: Bool {
            guard let pullRequest = pullRequest.pullRequest else { return false }
            return base.ref == "refs/remotes/origin/\(pullRequest.baseRefName)"
        }
    }

    enum Operation: String, Equatable, Sendable {
        case rebase
        case merge
        case cherryPick = "cherry-pick"
        case revert
        /// Unmerged paths with none of the above in progress.
        case conflicts
    }

    enum Outcome: Equatable, Sendable {
        case snapshot(Snapshot)
        /// A rebase, merge or conflict is in progress: the page pauses.
        case paused(Operation)
        /// Not a branch that can be reviewed (not a repository, detached
        /// HEAD, no commits, no base), or git failed: why.
        case unavailable(String)
    }
}
