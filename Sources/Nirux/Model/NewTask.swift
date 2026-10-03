import Foundation

/// New Task… (see NewTaskPanel): start an agent on a task from Nirux itself.
/// Nirux creates a worktree on a new branch, writes the handover (the
/// task's description and the template picked) and launches the agent in a
/// new workspace named after the task.
enum NewTask {
    /// Where a project's tasks branch from.
    struct Target: Equatable, Sendable {
        /// The repository's main checkout: git runs there, and new worktrees
        /// go next to it (see `GitWorktree.create`). A linked worktree when
        /// git can't tell where the main checkout is (a bare repository).
        let repository: String
        /// What the new branch starts from: `refs/remotes/origin/<branch>`,
        /// or `HEAD` when origin has none of the branches looked for.
        let startPoint: String
        /// `<branch>` of origin for a remote start point, fetched first.
        let remoteBranch: String?
        /// The branch `repository` has checked out, for a `HEAD` start point;
        /// nil when detached.
        let checkoutBranch: String?
        /// Where the project sits in the repository (`apps/web`), when its
        /// workspace isn't at the top: the task's workspace opens there too.
        let subdirectory: String?

        /// `origin/main`, for a remote start point.
        var remoteBranchName: String? { remoteBranch.map { "origin/\($0)" } }
    }

    /// A folder to look for the project's repository in. Only a workspace's
    /// own folder gives the project's place in it: a terminal may have
    /// `cd`'d anywhere.
    struct Folder: Equatable, Sendable {
        let path: String
        let isWorkspaceFolder: Bool
    }

    /// What the form sends to the shell once Start Task is clicked.
    struct Request: Sendable {
        let description: String
        let template: TaskTemplates.Template?
        let agent: NiruxApp.WorkspaceAgent
        let projectID: String
        let branch: String
        let target: Target
        /// False once the user chose to start without fetching, after a
        /// fetch failed.
        let fetchesFirst: Bool
    }

    // MARK: - Repository

    /// The repository of the first folder inside one, and where its tasks
    /// branch from: origin's `baseBranch` (the project's board setting, even
    /// when it was never fetched: the fetch at Start brings it), else
    /// origin's default branch, else its `main` or `master`, else the
    /// checkout's HEAD. Nil when no folder is in a git repository. Runs git
    /// (no network): call it off the main thread.
    static func resolveTarget(folders: [Folder], baseBranch: String?, gitPath: String = "/usr/bin/git") -> Target? {
        var seen = Set<String>()
        for folder in folders where seen.insert(URL(fileURLWithPath: folder.path).standardizedFileURL.path).inserted {
            guard let topLevel = GitWorktree.repoRoot(at: folder.path) else { continue }
            let checkout = GitWorktree.mainWorktreeRoot(of: topLevel)
            let subdirectory = folder.isWorkspaceFolder ? relativePath(of: folder.path, in: topLevel) : nil
            let hasOrigin = GitCommand.output(["remote"], cwd: checkout, gitPath: gitPath, timeout: 10)?
                .split(separator: "\n").contains("origin") == true
            let boardBase = baseBranch.flatMap { hasOrigin && BoardConfig.isValidBranchName($0) ? $0 : nil }
            let remoteBranch = boardBase ?? [
                BoardConfigSuggestions.defaultBranch(of: "origin", at: checkout, gitPath: gitPath), "main", "master"
            ].compactMap { $0 }.first { branch in
                GitCommand.output(
                    ["rev-parse", "--verify", "--quiet", "refs/remotes/origin/\(branch)^{commit}"],
                    cwd: checkout, gitPath: gitPath, timeout: 10
                ) != nil
            }
            return Target(
                repository: checkout,
                startPoint: remoteBranch.map { "refs/remotes/origin/\($0)" } ?? "HEAD",
                remoteBranch: remoteBranch,
                checkoutBranch: remoteBranch == nil ? GitWorktree.currentBranch(at: checkout) : nil,
                subdirectory: subdirectory
            )
        }
        return nil
    }

    /// Where the task's workspace opens: the project's folder in the new
    /// worktree, unless the branch lacks it or it leads out of the worktree
    /// (a link the repository commits), else the worktree.
    static func workingDirectory(in worktree: String, subdirectory: String?) -> String {
        var isDirectory: ObjCBool = false
        guard let subdirectory,
              let root = worktree.realPath,
              let folder = (worktree + "/" + subdirectory).realPath,
              folder.hasPrefix(root + "/"),
              FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue
        else { return worktree }
        return folder
    }

    /// `path` relative to `topLevel` (both resolved), or nil at the top.
    private static func relativePath(of path: String, in topLevel: String) -> String? {
        guard let folder = path.realPath, let top = topLevel.realPath, folder.hasPrefix(top + "/") else { return nil }
        let relative = String(folder.dropFirst(top.count + 1))
        return relative.isEmpty ? nil : relative
    }

    // MARK: - Names

    /// Longest slug a suggested branch gets after its `feat/` or `fix/`.
    static let maxSlugLength = 40
    static let maxTitleLength = 50

    /// First words of a description that make the branch a `fix/` one,
    /// left out of the slug: `fix/crash-on-launch`, not
    /// `fix/fix-crash-on-launch`.
    static let fixVerbs: Set<String> = ["fix", "fixes", "fixed", "bugfix", "hotfix", "corrige", "corriger"]
    /// First words that make it a `fix/` one too, but say what is broken:
    /// they stay in the slug (`fix/crash-on-launch`).
    static let bugWords: Set<String> = ["bug", "crash", "repair", "regression", "correction", "repare", "reparer"]

    /// `feat/<slug>` or `fix/<slug>` from the description's first line: its
    /// words in ASCII lowercase, joined by `-`, up to `maxSlugLength`. A
    /// `fix/` one when the template's name speaks of a bug or a fix, or the
    /// description starts with one of `fixVerbs` or `bugWords`. Empty when
    /// the line has no letter or digit to use. Always a valid branch name
    /// otherwise.
    static func suggestedBranch(description: String, templateName: String?) -> String {
        var words = slugWords(firstLine(of: description) ?? "")
        let template = templateName?.lowercased() ?? ""
        var isFix = template.contains("bug") || template.contains("fix")
        if let first = words.first, fixVerbs.contains(first) || bugWords.contains(first) {
            isFix = true
            if fixVerbs.contains(first), words.count > 1 { words.removeFirst() }
        }
        var slug = ""
        for word in words {
            let candidate = slug.isEmpty ? word : slug + "-" + word
            guard candidate.count <= maxSlugLength else { break }
            slug = candidate
        }
        if slug.isEmpty, let first = words.first {
            slug = String(first.prefix(maxSlugLength))
        }
        guard !slug.isEmpty else { return "" }
        return (isFix ? "fix/" : "feat/") + slug
    }

    /// The workspace's name: the description's first line, its whitespace
    /// collapsed, cut at `maxTitleLength`. Nil for a blank description.
    static func workspaceTitle(description: String) -> String? {
        guard let line = firstLine(of: description) else { return nil }
        let words = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard words.count > maxTitleLength else { return words }
        return String(words.prefix(maxTitleLength - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    private static func firstLine(of text: String) -> String? {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }

    /// Letters and digits in ASCII lowercase (accents dropped, other scripts
    /// transliterated), split at everything else.
    private static func slugWords(_ text: String) -> [String] {
        let latin = text.applyingTransform(.toLatin, reverse: false) ?? text
        let ascii = (latin.applyingTransform(.stripDiacritics, reverse: false) ?? latin).lowercased()
        return ascii.split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }.map(String.init)
    }

    // MARK: - Handover

    /// How the task's branch started, for the handover.
    enum Start: Equatable, Sendable {
        /// From origin's branch, fetched just before.
        case fetched(String)
        /// From origin's branch as last fetched: the fetch failed.
        case lastFetched(String)
        /// From the checkout's HEAD.
        case checkoutHead(repository: String, branch: String?)
    }

    /// The handover the agent reads first: the description as the user typed
    /// it, then the template's way of working.
    static func handover(
        description: String, template: TaskTemplates.Template?, branch: String, start: Start, subdirectory: String?
    ) -> String {
        let title = workspaceTitle(description: description) ?? branch
        let origin: String
        switch start {
        case .fetched(let remoteBranch):
            origin = "from \(remoteBranch), fetched just before."
        case .lastFetched(let remoteBranch):
            origin = "from \(remoteBranch) as last fetched: Nirux couldn’t fetch it, so fetch and rebase before you push."
        case .checkoutHead(let repository, let checkoutBranch):
            origin = "from the HEAD of \(repository)\(checkoutBranch.map { " (\($0))" } ?? ""): "
                + "origin has no default branch Nirux knows of."
        }
        var text = """
        # Task: \(title)

        The user started this session from Nirux (New Task…) for the task below, \
        on the new branch `\(branch)`, created \(origin)
        """
        if let subdirectory {
            text += " The project lives in `\(subdirectory)` of this repository."
        }
        text += """
         This file is for you only: never commit it.

        ## Task

        \(description.trimmingCharacters(in: .whitespacesAndNewlines))

        """
        if let template, !template.body.isEmpty {
            text += """

            ## How to proceed (template “\(template.name)”)

            \(template.body)

            """
        }
        return text
    }
}
