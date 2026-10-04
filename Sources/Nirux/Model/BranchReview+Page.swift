import Foundation

// MARK: - The page (section 2)

extension BranchReview {
    /// What the review page shows, as the JSON Swift sends it
    /// (`EditorAssets/review.js`). Everything from the branch (paths, the
    /// pull request, the commits, the handover) is the page's to show as
    /// text. Diffs aren't in it: the page asks for a file's when its row
    /// opens (`FileDiff`).
    struct Page: Encodable, Equatable, Sendable {
        struct Header: Encodable, Equatable, Sendable {
            let branch: String
            let base: String
            let head: String
            /// What the diffs are from: a diff shown for a file keeps only
            /// while it and the file's patch stay the same.
            let mergeBase: String
            let pullRequest: PullRequestSummary?
            let commits: Int
            /// Merges that brought in the base branch, among `commits`.
            let mergesFromBase: Int
            let files: Int
            let additions: Int
            let deletions: Int
            /// When the branch was read, ISO 8601: the page doesn't follow
            /// the worktree yet, and says how old it is.
            let readAt: String
            /// What the reader should know before trusting the page, as
            /// sentences: uncommitted changes, unpushed commits, a pull
            /// request ahead of the worktree, a failed fetch.
            let notes: [String]
        }

        struct PullRequestSummary: Encodable, Equatable, Sendable {
            let number: Int
            let title: String
            let url: String
            let isDraft: Bool
        }

        /// One block of "What and why", labeled with where it comes from.
        struct Account: Encodable, Equatable, Sendable {
            enum Source: String, Encodable, Sendable {
                case pullRequest
                case handover
                case commits
            }

            let source: Source
            /// "Pull request #57", ".claude-handover.md", "3 commits".
            let label: String
            /// Markdown for the pull request and the handover.
            let title: String?
            let text: String
            /// The commits, newest last, merges from the base left out.
            let commits: [CommitSummary]?
        }

        struct CommitSummary: Encodable, Equatable, Sendable {
            let oid: String
            let subject: String
            let body: String
        }

        /// One risk chip (section 5): how many files raise it, and what
        /// raised it, most frequent first.
        struct Risk: Encodable, Equatable, Sendable {
            let kind: String
            let label: String
            let files: Int
            let reasons: [String]
        }

        struct Tests: Encodable, Equatable, Sendable {
            struct Name: Encodable, Equatable, Sendable {
                /// `Outer.name` for a member.
                let name: String
                let path: String
                let line: Int
            }

            let testLines: Int
            let codeLines: Int
            let declared: Int
            let unmentioned: [Name]
            let unscannedFiles: [String]
            let unreadTestFiles: Int
            let testFilesUnlisted: Bool
        }

        struct File: Encodable, Equatable, Sendable {
            /// Its index in the snapshot: what the page asks for its diff by.
            let id: Int
            let path: String
            let oldPath: String?
            let status: String
            let additions: Int
            let deletions: Int
            let isBinary: Bool
            let isUntracked: Bool
            let isUncommitted: Bool
            /// Why its hunks aren't in the snapshot: "tooLarge", "onDemand",
            /// "notRead".
            let omission: String?
            let fold: String?
            /// Risk kinds, in `RiskKind` order.
            let risks: [String]
            /// `BranchReview.patchHash`; nil when its patch wasn't read.
            let patchHash: String?
            /// What a diff drawn for it shows: the patch hash and the
            /// hunks' ranges, which with the merge base fix its context and
            /// line numbers (the patch hash leaves them out). Nil when its
            /// hunks aren't in the snapshot: its diff is read again.
            let diffKey: String?
        }

        struct Group: Encodable, Equatable, Sendable {
            /// "uncommitted", a path group ("code"), or a fold
            /// ("folded.lockfile").
            let key: String
            let title: String
            /// Collapsed, counted, never hidden.
            let isFolded: Bool
            /// File ids, in the group's order.
            let files: [Int]
        }

        /// Counts the snapshots the column showed: the page sends it back
        /// with a row's id, so that an id is read against its own snapshot.
        let generation: Int
        let header: Header
        let accounts: [Account]
        let risks: [Risk]
        let tests: Tests
        let groups: [Group]
        let files: [File]
    }

    /// The author's notes for the next session, found in the worktree.
    struct Handover: Equatable, Sendable {
        static let names = [".claude-handover.md", ".codex-handover.md"]
        /// Past this, the page shows the beginning and says it is cut.
        static let maxBytes = 64_000

        let name: String
        let text: String
        let isCut: Bool

        /// The first handover found at the worktree's top level, read
        /// lossily: a regular file only. A branch can commit a link in its
        /// place, to a key or anything else on the Mac, or a FIFO that
        /// would block the read forever. Call it off the main thread.
        static func read(in root: String) -> Handover? {
            for name in names {
                let path = (root as NSString).appendingPathComponent(name)
                let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard descriptor >= 0 else { continue }
                let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                var info = stat()
                guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { continue }
                // One byte more than shown says whether it was cut.
                guard let data = try? handle.read(upToCount: maxBytes + 1) else { continue }
                let isCut = data.count > maxBytes
                return Handover(name: name, text: String(decoding: data.prefix(maxBytes), as: UTF8.self), isCut: isCut)
            }
            return nil
        }
    }

    static func page(for snapshot: Snapshot, handover: Handover?, generation: Int = 0, readAt: Date = Date()) -> Page {
        // One entry per path (`Snapshot.files`).
        let ids = Dictionary(snapshot.files.enumerated().map { ($1.path, $0) }) { first, _ in first }
        return Page(
            generation: generation,
            header: header(of: snapshot, readAt: readAt),
            accounts: accounts(of: snapshot, handover: handover),
            risks: risks(of: snapshot.files),
            tests: tests(of: snapshot.testsAgainstCode),
            groups: snapshot.groups.map { group in
                Page.Group(
                    key: group.kind.key, title: group.kind.title, isFolded: group.kind.isFolded,
                    files: group.paths.compactMap { ids[$0] }
                )
            },
            files: snapshot.files.enumerated().map { id, file in
                Page.File(
                    id: id, path: file.path, oldPath: file.oldPath, status: file.status.rawValue,
                    additions: file.additions, deletions: file.deletions, isBinary: file.isBinary,
                    isUntracked: file.isUntracked, isUncommitted: file.isUncommitted,
                    omission: file.omission.map(\.key), fold: file.fold?.rawValue,
                    risks: file.signals.map(\.kind.rawValue), patchHash: file.patchHash, diffKey: diffKey(of: file)
                )
            }
        )
    }

    static func diffKey(of file: FileChange) -> String? {
        guard let patchHash = file.patchHash, !file.hunks.isEmpty else { return nil }
        let ranges = file.hunks.map { "\($0.oldStart),\($0.oldCount),\($0.newStart),\($0.newCount)" }
        return patchHash + ":" + ranges.joined(separator: ";")
    }

    private static func header(of snapshot: Snapshot, readAt: Date) -> Page.Header {
        let pullRequest = snapshot.pullRequest.pullRequest
        return Page.Header(
            branch: snapshot.branch,
            base: snapshot.base.name,
            head: snapshot.head,
            mergeBase: snapshot.base.mergeBase,
            pullRequest: pullRequest.map {
                Page.PullRequestSummary(number: $0.number, title: $0.title, url: $0.url, isDraft: $0.isDraft)
            },
            commits: snapshot.commits.count,
            mergesFromBase: snapshot.commits.filter(\.isMergeFromBase).count,
            files: snapshot.files.count,
            additions: snapshot.files.reduce(0) { $0 + $1.additions },
            deletions: snapshot.files.reduce(0) { $0 + $1.deletions },
            readAt: readAt.formatted(.iso8601),
            notes: notes(of: snapshot)
        )
    }

    static func notes(of snapshot: Snapshot) -> [String] {
        var notes: [String] = []
        if snapshot.hasUncommittedChanges {
            notes.append("Some changes aren’t committed: they’re in “Not committed”, not in the branch’s commits yet.")
        }
        if case .counted(let ahead, let behind) = snapshot.upstream {
            if ahead > 0 { notes.append(count(ahead, "commit") + " not pushed.") }
            if behind > 0 { notes.append("The remote branch has " + count(behind, "commit") + " this worktree doesn’t.") }
        }
        if let pullRequest = snapshot.pullRequest.pullRequest {
            switch snapshot.pullRequestHead {
            case .counted(let ahead, let behind)?:
                // The upstream is often the pull request's head: its note
                // already counts these commits.
                if ahead > 0, snapshot.upstream == nil {
                    notes.append(count(ahead, "local commit") + " not in pull request #\(pullRequest.number).")
                }
                if behind > 0, snapshot.upstream != .counted(ahead: ahead, behind: behind) {
                    notes.append("Pull request #\(pullRequest.number) has " + count(behind, "commit") + " this worktree doesn’t.")
                }
            case .notLocal?:
                notes.append("Pull request #\(pullRequest.number) has commits this worktree doesn’t have.")
            case nil:
                break
            }
            if !snapshot.usesPullRequestBase {
                // A base without a remote (no `origin`) is the local branch.
                let base = snapshot.base.ref.hasPrefix("refs/heads/") ? "the local \(snapshot.base.name)" : snapshot.base.name
                notes.append(
                    "Compared with \(base), not with the pull request’s base \(pullRequest.baseRefName): "
                        + "Nirux couldn’t use it."
                )
            }
        } else if case .unavailable(let reason) = snapshot.pullRequest {
            notes.append("No pull request information: \(reason)")
        }
        if let problem = snapshot.fetchProblem {
            // What was fetched is a pull request's base, which the problem
            // names: the branch's, or a candidate's without it.
            let what = snapshot.pullRequest.pullRequest == nil ? "a pull request’s base" : "the pull request’s base"
            notes.append("Nirux couldn’t fetch \(what): \(problem)")
        }
        return notes
    }

    private static func accounts(of snapshot: Snapshot, handover: Handover?) -> [Page.Account] {
        var accounts: [Page.Account] = []
        if let pullRequest = snapshot.pullRequest.pullRequest {
            accounts.append(Page.Account(
                source: .pullRequest, label: "Pull request #\(pullRequest.number)", title: pullRequest.title,
                text: pullRequest.body, commits: nil
            ))
        }
        if let handover {
            accounts.append(Page.Account(
                source: .handover, label: handover.name + (handover.isCut ? " (beginning)" : ""), title: nil,
                text: handover.text, commits: nil
            ))
        }
        let commits = snapshot.commits.filter { !$0.isMergeFromBase }.reversed()
            .map { Page.CommitSummary(oid: $0.oid, subject: $0.subject, body: $0.body) }
        if !commits.isEmpty {
            accounts.append(Page.Account(
                source: .commits, label: count(commits.count, "commit"), title: nil, text: "", commits: commits
            ))
        }
        return accounts
    }

    private static func risks(of files: [FileChange]) -> [Page.Risk] {
        RiskKind.allCases.map { kind in
            let signals = files.compactMap { $0.signals.first { $0.kind == kind } }
            var frequency: [String: Int] = [:]
            for reason in signals.flatMap(\.reasons) { frequency[reason, default: 0] += 1 }
            let reasons = frequency.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map(\.key)
            return Page.Risk(kind: kind.rawValue, label: kind.label, files: signals.count, reasons: reasons)
        }
    }

    private static func tests(of tests: TestsAgainstCode) -> Page.Tests {
        Page.Tests(
            testLines: tests.testLines, codeLines: tests.codeLines, declared: tests.declared,
            unmentioned: tests.unmentioned.map {
                Page.Tests.Name(
                    name: [$0.symbol.container, $0.symbol.name].compactMap { $0 }.joined(separator: "."),
                    path: $0.path, line: $0.symbol.line
                )
            },
            unscannedFiles: tests.unscannedFiles, unreadTestFiles: tests.unreadTestFiles,
            testFilesUnlisted: tests.testFilesUnlisted
        )
    }

    /// "1 commit", "3 commits".
    static func count(_ number: Int, _ noun: String) -> String {
        "\(number) \(noun)\(number == 1 ? "" : "s")"
    }
}

// MARK: - A file's diff, on demand

extension BranchReview {
    /// The diff the page asks for when a row opens: the hunks, or why there
    /// are none to show.
    struct FileDiff: Encodable, Equatable, Sendable {
        struct Hunk: Encodable, Equatable, Sendable {
            let oldStart: Int
            let newStart: Int
            let section: String
            let lines: [Line]
        }

        struct Line: Encodable, Equatable, Sendable {
            /// "context", "added", "removed", "noNewlineMarker", as
            /// `createReview` reads them.
            let kind: String
            let text: String
        }

        let id: Int
        /// The file's path, and the page's generation it was asked for: the
        /// page drops a diff that isn't its row's.
        let path: String
        let generation: Int
        let hunks: [Hunk]
        /// Shown in place of the hunks: a binary file, one too large, a
        /// rename or mode change without lines, a read that failed.
        let message: String?

        init(id: Int, path: String, generation: Int, hunks: [Hunk] = [], message: String? = nil) {
            self.id = id
            self.path = path
            self.generation = generation
            self.hunks = hunks
            self.message = message
        }

        /// What `file` shows as it is in the snapshot; nil when its hunks
        /// must be read first (`.onDemand`, `.notRead`).
        init?(id: Int, generation: Int, file: FileChange) {
            if file.isBinary {
                self.init(id: id, path: file.path, generation: generation, message: "Binary file.")
                return
            }
            switch file.omission {
            case .onDemand?, .notRead?:
                return nil
            case .tooLarge?, nil:
                self.init(id: id, generation: generation, read: file)
            }
        }

        /// `file` as `filePatch` read it.
        init(id: Int, generation: Int, read file: FileChange) {
            if file.isBinary {
                self.init(id: id, path: file.path, generation: generation, message: "Binary file.")
            } else if file.omission == .tooLarge {
                self.init(
                    id: id, path: file.path, generation: generation,
                    message: "Too large to show here (\(Self.size(file.patchBytes)) of diff)."
                )
            } else if file.omission != nil {
                // Still not read: past the size git's whole diff may take,
                // or git didn't finish in time.
                self.init(
                    id: id, path: file.path, generation: generation,
                    message: "Nirux couldn’t read this file’s diff: too large, or git took too long."
                )
            } else if file.hunks.isEmpty {
                self.init(id: id, path: file.path, generation: generation, message: Self.withoutLines(file))
            } else {
                self.init(id: id, path: file.path, generation: generation, hunks: file.hunks.map { hunk in
                    Hunk(
                        oldStart: hunk.oldStart, newStart: hunk.newStart, section: hunk.section,
                        lines: hunk.lines.map { Line(kind: $0.kind.key, text: $0.text) }
                    )
                })
            }
        }

        private static func withoutLines(_ file: FileChange) -> String {
            if let oldMode = file.oldMode, let newMode = file.newMode, oldMode != newMode {
                return "Mode changed from \(oldMode) to \(newMode)."
            }
            switch file.status {
            case .renamed: return "Renamed, no line changed."
            case .added: return "Empty file added."
            case .deleted: return "Empty file deleted."
            case .typeChanged: return "Became a link or a submodule, or stopped being one."
            case .modified: return "No line changed."
            }
        }

        private static func size(_ bytes: Int) -> String {
            ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        }
    }
}

extension BranchReview.FileGroup.Kind {
    var key: String {
        switch self {
        case .uncommitted: return "uncommitted"
        case .path(let group): return group.rawValue
        case .folded(let fold): return "folded." + fold.rawValue
        }
    }

    var title: String {
        switch self {
        case .uncommitted: return "Not committed"
        case .path(.code): return "Code"
        case .path(.tests): return "Tests"
        case .path(.config): return "Config and dependencies"
        case .path(.ci): return "CI"
        case .path(.docs): return "Docs"
        case .folded(.lockfile): return "Lockfiles"
        case .folded(.generated): return "Generated files"
        case .folded(.pureRename): return "Pure renames"
        case .folded(.whitespaceOnly): return "Whitespace only"
        case .folded(.binary): return "Binary files"
        }
    }

    var isFolded: Bool {
        if case .folded = self { return true }
        return false
    }
}

extension BranchReview.RiskKind {
    var label: String {
        switch self {
        case .persistence: return "Persistence"
        case .security: return "Security"
        case .concurrency: return "Concurrency"
        case .launch: return "Launch and quit"
        case .ci: return "CI workflows"
        case .sideEffects: return "Outside Nirux"
        case .dependencies: return "Dependencies"
        }
    }
}

extension BranchReview.Omission {
    var key: String {
        switch self {
        case .tooLarge: return "tooLarge"
        case .onDemand: return "onDemand"
        case .notRead: return "notRead"
        }
    }
}

extension BranchReview.Line.Kind {
    var key: String {
        switch self {
        case .context: return "context"
        case .added: return "added"
        case .removed: return "removed"
        case .noNewlineMarker: return "noNewlineMarker"
        }
    }
}
