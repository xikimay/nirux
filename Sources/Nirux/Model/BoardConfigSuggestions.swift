import Foundation

/// What Board Settings proposes for the values board.json doesn't set,
/// read from the project's local checkouts with git. Never from the
/// network, and never written without Save.
struct BoardConfigSuggestions: Equatable, Sendable {
    /// A workspace folder inside a git repository.
    struct Folder: Equatable, Sendable {
        /// The github.com repository (`owner/name`, lowercased) its branch is
        /// pushed to. Nil when that remote isn't on github.com, or is missing.
        let repository: String?
        /// That remote: the branch's push remote, else `origin`.
        let remote: String
        /// Where the repository's workflow files and default branch are
        /// read: the main working tree, or the folder's own top level for a
        /// bare repository.
        let checkout: String
    }

    enum RepositorySource: Equatable, Sendable {
        /// Every workspace folder in a repository pushes to it.
        case shared
        /// They push to several repositories, listed; "no GitHub remote"
        /// stands for the folders without one.
        case differing([String])
        /// No workspace folder is in a git repository.
        case noRepository
    }

    /// The repository to suggest: the one every workspace in a repository
    /// pushes to. Nil unless `source` is `.shared`.
    var repository: String?
    var source: RepositorySource
    /// A local checkout of the repository in use (the saved one, else the
    /// suggested one). Nil when no workspace pushes to it.
    var checkout: String?
    /// The checkout's `refs/remotes/<remote>/HEAD`, without the remote's name.
    var baseBranch: String?
    /// `.github/workflows/*.yml|yaml` in the checkout, sorted. Nil without a
    /// checkout: the form then asks for a name.
    var workflowFiles: [String]?

    static let noGitHubRemote = "no GitHub remote"

    /// Runs git in every folder: call it off the main thread. `repository`
    /// is the saved one, if any: the checkout comes from a folder that
    /// pushes to it.
    static func read(
        workspaceFolders: [String], repository saved: String?, gitPath: String = "/usr/bin/git"
    ) -> BoardConfigSuggestions {
        var seen = Set<String>()
        let folders = workspaceFolders
            .filter { seen.insert(URL(fileURLWithPath: $0).standardizedFileURL.path).inserted }
            .compactMap { folder(at: $0, gitPath: gitPath) }
        var suggestions = combine(folders, repository: saved)
        if let folder = checkoutFolder(folders, repository: saved ?? suggestions.repository) {
            suggestions.baseBranch = defaultBranch(of: folder.remote, at: folder.checkout, gitPath: gitPath)
            suggestions.workflowFiles = workflowFiles(in: folder.checkout)
        }
        return suggestions
    }

    /// The suggested repository, and the checkout to read: the first folder
    /// pushing to `saved`, else to the suggested repository.
    static func combine(_ folders: [Folder], repository saved: String?) -> BoardConfigSuggestions {
        let repositories = folders.map(\.repository)
        let source: RepositorySource
        var repository: String?
        if folders.isEmpty {
            source = .noRepository
        } else if let first = repositories.first, let shared = first, repositories.allSatisfy({ $0 == shared }) {
            source = .shared
            repository = shared
        } else {
            var listed: [String] = []
            for name in repositories.map({ $0 ?? noGitHubRemote }) where !listed.contains(name) {
                listed.append(name)
            }
            source = .differing(listed)
        }
        let checkout = checkoutFolder(folders, repository: saved ?? repository)?.checkout
        return BoardConfigSuggestions(repository: repository, source: source, checkout: checkout)
    }

    /// The first folder pushing to `repository`, compared without case.
    private static func checkoutFolder(_ folders: [Folder], repository: String?) -> Folder? {
        guard let wanted = repository?.lowercased() else { return nil }
        return folders.first { $0.repository == wanted }
    }

    /// Nil outside a git repository (or a folder that's gone).
    static func folder(at path: String, gitPath: String = "/usr/bin/git") -> Folder? {
        let git = { (arguments: [String]) in
            GitCommand.output(arguments, cwd: path, gitPath: gitPath, timeout: 10)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let topLevel = git(["rev-parse", "--show-toplevel"]), !topLevel.isEmpty else { return nil }
        var remote = "origin"
        if let branch = git(["symbolic-ref", "--quiet", "--short", "HEAD"]), !branch.isEmpty,
           let pushRemote = git(["for-each-ref", "--format=%(push:remotename)", "refs/heads/\(branch)"]),
           !pushRemote.isEmpty, pushRemote != "." {
            remote = pushRemote
        }
        let repository = git(["remote", "get-url", "--push", "--", remote])
            .flatMap { GitHubRepository(remoteURL: $0) }
            .flatMap { $0.host == "github.com" ? "\($0.owner)/\($0.name)" : nil }
        let checkout = GitCommand.output(["worktree", "list", "--porcelain", "-z"], cwd: path, gitPath: gitPath, timeout: 10)
            .flatMap(mainWorkingTree(inListing:)) ?? topLevel
        return Folder(repository: repository, remote: remote, checkout: checkout)
    }

    /// The first entry of `git worktree list --porcelain -z`, unless it is
    /// a bare repository, which has no files.
    static func mainWorkingTree(inListing listing: String) -> String? {
        let fields = listing.split(separator: "\0", omittingEmptySubsequences: false)
        guard let first = fields.first, first.hasPrefix("worktree ") else { return nil }
        let entry = fields.prefix { !$0.isEmpty }
        return entry.contains("bare") ? nil : String(first.dropFirst("worktree ".count))
    }

    /// `refs/remotes/<remote>/HEAD`, as a branch name. Nil when it isn't set
    /// (a clone made with `git init` + `fetch`, say): the user types it.
    static func defaultBranch(of remote: String, at checkout: String, gitPath: String = "/usr/bin/git") -> String? {
        guard let target = GitCommand.output(
            ["symbolic-ref", "--quiet", "--short", "refs/remotes/\(remote)/HEAD"],
            cwd: checkout, gitPath: gitPath, timeout: 10
        )?.trimmingCharacters(in: .whitespacesAndNewlines), !target.isEmpty
        else { return nil }
        let prefix = remote + "/"
        let branch = target.hasPrefix(prefix) ? String(target.dropFirst(prefix.count)) : target
        return branch.isEmpty ? nil : branch
    }

    /// The workflow files GitHub runs: `.yml` and `.yaml` files directly in
    /// `.github/workflows`.
    static func workflowFiles(in checkout: String) -> [String] {
        let folder = URL(fileURLWithPath: checkout).appendingPathComponent(".github/workflows", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { name in
            guard BoardConfig.isValidWorkflowFile(name) else { return false }
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path, isDirectory: &isDirectory)
                && !isDirectory.boolValue
        }.sorted()
    }
}
