import Foundation

/// The Project Board (docs/project-board.md): one table per project of the
/// branches its agents work on, with their workspaces, agents, pull
/// requests and checks. B1 only reads: nothing here changes a repository.
///
/// This file holds the pure types and the row builder (section 2). The
/// `gh` client and its parsers, the refresh schedule and the agent states
/// are in the other `ProjectBoard+` files; `ProjectBoardController` reads,
/// `ProjectBoardView` draws.
enum ProjectBoard {}

// MARK: - What GitHub says

extension ProjectBoard {
    /// A check run's or a commit status's outcome, in the order the board
    /// shows the worst of several: a skipped or neutral check doesn't hide
    /// a success. (The merge queue has its own rules: neither is green.)
    enum CheckResult: Int, Comparable, Sendable {
        case skipped
        case neutral
        case success
        case pending
        case failure

        static func < (lhs: CheckResult, rhs: CheckResult) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// One entry of a pull request's `statusCheckRollup`: a check run, or a
    /// commit status (`context`). For display only: the rollup carries no
    /// commit, so the merge queue reads checks by commit instead.
    struct Check: Equatable, Sendable {
        /// The job's name, or a commit status's context.
        let name: String
        /// The check run's workflow. Nil (or empty) for a commit status, or
        /// a check run no workflow made (CodeQL's summary check).
        let workflowName: String?
        let result: CheckResult
        /// ISO 8601. Of two runs of one check, the later one counts.
        let startedAt: String?

        /// `Workflow / job`, as board.json may name it.
        var qualifiedName: String? {
            guard let workflowName, !workflowName.isEmpty else { return nil }
            return "\(workflowName) / \(name)"
        }

        func matches(_ required: String) -> Bool {
            name == required || qualifiedName == required
        }
    }

    struct PullRequest: Equatable, Sendable {
        let number: Int
        /// OPEN, MERGED or CLOSED.
        let state: String
        let headRefName: String
        let headOid: String
        let baseRefName: String?
        let isDraft: Bool
        /// MERGEABLE, CONFLICTING or UNKNOWN (GitHub is recomputing it).
        let mergeable: String?
        let checks: [Check]
        let url: String
        /// Its head repository is the configured one. A fork's pull
        /// request matches no branch and gets no row.
        let isFromConfiguredRepository: Bool

        var isOpen: Bool { state == "OPEN" }
        var isConflicting: Bool { mergeable == "CONFLICTING" }
    }

    /// The last run of the post-merge workflow on the base branch.
    struct WorkflowRun: Equatable, Sendable {
        /// `completed`, `in_progress`, `queued`…
        let status: String
        /// `success`, `failure`, `cancelled`… once completed.
        let conclusion: String?
        let headSha: String
        let createdAt: Date?
        let updatedAt: Date?
        let url: String?
    }
}

// MARK: - What the Mac says

extension ProjectBoard {
    /// A local repository the project's workspaces are in: its worktrees
    /// as `git worktree list` gives them, paths comparable (symlinks
    /// resolved), and the GitHub repositories its remotes point to.
    struct LocalRepository: Equatable, Sendable {
        /// The main working tree (or the bare repository) first.
        let worktrees: [WorktreeCleanup.ListedWorktree]
        let remotes: [GitHubRepository]
    }

    /// A workspace of the project, active or inactive.
    struct Workspace: Equatable {
        let id: String
        let title: String
        /// Its launch folder, comparable like the worktrees' paths.
        let folder: String
        /// The folder no longer exists (its worktree was removed): the
        /// workspace gets a row of its own, not the enclosing worktree's.
        var folderIsGone = false
        let isInactive: Bool
        /// Its most urgent agent column.
        let agent: Agent
    }

    struct WorkspaceRef: Equatable {
        let id: String
        let title: String
        let isInactive: Bool
    }
}

extension ProjectBoard.Workspace {
    var reference: ProjectBoard.WorkspaceRef { ProjectBoard.WorkspaceRef(id: id, title: title, isInactive: isInactive) }
}

// MARK: - Rows

extension ProjectBoard {
    enum RowGroup: Hashable {
        /// A main working tree, whatever branch it is on.
        case main
        /// A branch with an open pull request or a workspace.
        case active
        /// A worktree with neither: shown folded, with Open and Clean Up.
        case otherWorktree
        /// Workspaces in another repository, or outside any: no PR columns.
        case otherRepository
    }

    /// A branch of the project's repository, or a folder of one of its
    /// workspaces outside it.
    struct Row: Equatable {
        let group: RowGroup
        /// The worktree's top level. Nil for a pull request without a
        /// local worktree, and for a folder outside any repository.
        let worktreePath: String?
        let branch: String?
        /// The commit of a worktree on a detached HEAD, which shows no pull
        /// request until it is back on its branch.
        let detachedHead: String?
        /// The workspaces open in the worktree (or the folder), in sidebar order.
        let workspaces: [WorkspaceRef]
        /// Its open pull request, else one merged recently from its branch.
        let pullRequest: PullRequest?
        /// The most urgent agent column among `workspaces`.
        var agent: Agent
        /// A workspace's folder outside any repository, or gone.
        let folder: String?
        /// `folder` no longer exists: only its workspaces are left to close.
        var folderIsGone = false

        /// The first workspace's title, else the branch, else the folder.
        var name: String {
            if let title = workspaces.first?.title { return title }
            if let branch { return branch }
            if let detachedHead { return "detached HEAD (\(WorktreeCleanup.short(detachedHead)))" }
            let path = worktreePath ?? folder ?? ""
            return (path as NSString).lastPathComponent
        }

        /// A linked worktree of the project, which the clean-up may delete,
        /// or a folder already gone, whose workspaces it closes.
        var canCleanUp: Bool {
            folderIsGone || (worktreePath != nil && group != .main && group != .otherRepository)
        }
    }

    /// Everything the rows come from.
    struct Sources {
        /// The configured repository. Nil: no local repository is the
        /// project's, and pull requests aren't read.
        var repository: GitHubRepository?
        var local: [LocalRepository] = []
        var workspaces: [Workspace] = []
        var openPullRequests: [PullRequest] = []
        var mergedPullRequests: [PullRequest] = []
    }

    /// The rows, in board order (section 2):
    /// 1. the main working tree of each of the project's local repositories;
    /// 2. branches with an open pull request (oldest first), then branches
    ///    with a workspace but none;
    /// 3. the other worktrees, with neither;
    /// 4. workspaces in another repository, or outside any.
    ///
    /// A workspace belongs to the worktree that holds its launch folder,
    /// the longest match (worktrees may sit inside the main checkout). A
    /// worktree belongs to the open pull request of its branch, else to a
    /// merged one whose head it is still at; only pull requests from the
    /// configured repository match, and none without one. Bare and
    /// prunable entries get no row.
    static func rows(_ sources: Sources) -> [Row] {
        let places = self.places(in: sources.local)
        let (members, outside) = assign(sources.workspaces, to: places)
        let configured = sources.repository != nil
        let open = latestByBranch(sources.openPullRequests.filter { configured && $0.isFromConfiguredRepository && $0.isOpen })
        let merged = latestByBranch(sources.mergedPullRequests.filter {
            configured && $0.isFromConfiguredRepository && $0.state == "MERGED"
        })

        var byGroup: [RowGroup: [Row]] = [:]
        var foreign: [(order: Int, row: Row)] = []
        var branchesWithWorktree: Set<String> = []
        for (index, place) in places.enumerated() {
            let repository = sources.local[place.repository]
            let worktree = repository.worktrees[place.entry]
            let inside = members[index] ?? []
            // By owner and name: an SSH host alias (`git@github-work:…`)
            // points at github.com all the same.
            let isProjects = sources.repository.map { configured in
                repository.remotes.contains { $0.owner == configured.owner && $0.name == configured.name }
            } ?? false
            guard isProjects else {
                if let first = inside.first {
                    foreign.append((first.order, row(.otherRepository, worktree: worktree, inside: inside, pullRequest: nil)))
                }
                continue
            }
            // A merged pull request only if the worktree is still at its
            // head: a branch name reused since has new work.
            let pullRequest = worktree.branch.flatMap { branch in
                open[branch] ?? merged[branch].flatMap { $0.headOid == worktree.head?.lowercased() ? $0 : nil }
            }
            if let branch = worktree.branch { branchesWithWorktree.insert(branch) }
            let group: RowGroup
            if place.entry == 0 {
                group = .main
            } else if pullRequest?.isOpen == true || !inside.isEmpty {
                group = .active
            } else {
                group = .otherWorktree
            }
            byGroup[group, default: []].append(row(group, worktree: worktree, inside: inside, pullRequest: pullRequest))
        }

        // Pull requests with no local worktree: a cloud session's, say.
        for pullRequest in open.values where !branchesWithWorktree.contains(pullRequest.headRefName) {
            byGroup[.active, default: []].append(Row(
                group: .active, worktreePath: nil, branch: pullRequest.headRefName, detachedHead: nil,
                workspaces: [], pullRequest: pullRequest, agent: Agent(), folder: nil
            ))
        }
        foreign += outsideRows(outside)

        let byName = { (lhs: Row, rhs: Row) in lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending }
        let active = byGroup[.active] ?? []
        let withOpenPullRequest = active.filter { $0.pullRequest?.isOpen == true }
            .sorted { ($0.pullRequest?.number ?? 0) < ($1.pullRequest?.number ?? 0) }
        let withoutOpenPullRequest = active.filter { $0.pullRequest?.isOpen != true }.sorted(by: byName)
        return (byGroup[.main] ?? []) + withOpenPullRequest + withoutOpenPullRequest
            + (byGroup[.otherWorktree] ?? []).sorted(by: byName)
            + foreign.sorted { $0.order < $1.order }.map(\.row)
    }

    /// A worktree a workspace can be in: listed, not bare, folder still there.
    private struct Place {
        let path: String
        let repository: Int
        let entry: Int
    }

    private typealias Member = (order: Int, workspace: Workspace)

    private static func places(in local: [LocalRepository]) -> [Place] {
        local.enumerated().flatMap { repositoryIndex, repository in
            repository.worktrees.enumerated().compactMap { entryIndex, worktree in
                worktree.isBare || worktree.isPrunable
                    ? nil
                    : Place(path: worktree.path, repository: repositoryIndex, entry: entryIndex)
            }
        }
    }

    /// Each workspace in the innermost place holding its folder, keyed by
    /// the place's index; the others outside, in sidebar order.
    private static func assign(_ workspaces: [Workspace], to places: [Place]) -> ([Int: [Member]], [Member]) {
        var members: [Int: [Member]] = [:]
        var outside: [Member] = []
        let paths = places.map(\.path)
        for (order, workspace) in workspaces.enumerated() {
            guard !workspace.folderIsGone else {
                outside.append((order, workspace))
                continue
            }
            if let holding = innermost(of: paths, holding: workspace.folder) {
                members[holding, default: []].append((order, workspace))
            } else {
                outside.append((order, workspace))
            }
        }
        return (members, outside)
    }

    private static func row(
        _ group: RowGroup, worktree: WorktreeCleanup.ListedWorktree, inside: [Member], pullRequest: PullRequest?
    ) -> Row {
        Row(
            group: group, worktreePath: worktree.path, branch: worktree.branch,
            detachedHead: worktree.branch == nil ? worktree.head : nil, workspaces: inside.map(\.workspace.reference),
            pullRequest: pullRequest, agent: Agent.mostUrgent(inside.map(\.workspace.agent)), folder: nil
        )
    }

    /// Outside any repository: one row per folder, first seen first.
    private static func outsideRows(_ outside: [Member]) -> [(order: Int, row: Row)] {
        var folders: [String] = []
        var byFolder: [String: [Member]] = [:]
        for member in outside {
            if byFolder[member.workspace.folder] == nil { folders.append(member.workspace.folder) }
            byFolder[member.workspace.folder, default: []].append(member)
        }
        return folders.compactMap { folder in
            guard let inside = byFolder[folder], let first = inside.first else { return nil }
            return (first.order, Row(
                group: .otherRepository, worktreePath: nil, branch: nil, detachedHead: nil,
                workspaces: inside.map(\.workspace.reference), pullRequest: nil,
                agent: Agent.mostUrgent(inside.map(\.workspace.agent)), folder: folder,
                folderIsGone: inside.allSatisfy(\.workspace.folderIsGone)
            ))
        }
    }

    /// Whether `path` is `root` or inside it. Both comparable.
    static func contains(_ root: String, _ path: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    /// The index of the root holding `path`, the innermost one when they
    /// nest (a worktree inside the main checkout).
    static func innermost(of roots: [String], holding path: String) -> Int? {
        roots.indices.filter { contains(roots[$0], path) }.max { roots[$0].count < roots[$1].count }
    }

    /// The newest pull request of each head branch.
    private static func latestByBranch(_ pullRequests: [PullRequest]) -> [String: PullRequest] {
        var latest: [String: PullRequest] = [:]
        for pullRequest in pullRequests where (latest[pullRequest.headRefName]?.number ?? .min) < pullRequest.number {
            latest[pullRequest.headRefName] = pullRequest
        }
        return latest
    }
}
