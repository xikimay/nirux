import Foundation

/// What Board Settings proposes for the values board.json doesn't set,
/// read from the project's local checkouts with git. Never from the
/// network, and never written without Save.
struct BoardConfigSuggestions: Equatable, Sendable {
    /// A workspace folder inside a git repository.
    struct Folder: Equatable, Sendable {
        /// The github.com repository (`owner/name`, spelled as in the remote's
        /// URL) its pull requests live in (`GitHubBaseRemote`). Nil when no
        /// remote is on github.com.
        let repository: String?
        /// That remote; else the first remote, else `origin`.
        let remote: String
        /// Where the repository's workflow files and default branch are
        /// read: the main working tree, or the folder's own top level for a
        /// bare repository.
        let checkout: String
    }

    enum RepositorySource: Equatable, Sendable {
        /// Every workspace folder in a repository has its pull requests there.
        case shared
        /// They are in several repositories, listed; `noGitHubRemote`
        /// stands for the folders without one.
        case differing([String])
        /// No workspace folder is in a git repository.
        case noRepository
    }

    /// The repository to suggest: the one every workspace in a repository
    /// has its pull requests in. Nil unless `source` is `.shared`.
    var repository: String?
    var source: RepositorySource
    /// A local checkout of the repository in use (the saved one, else the
    /// suggested one). Nil when no workspace is in it.
    var checkout: String?
    /// The branch the checkout's `refs/remotes/<remote>/HEAD` points to, if
    /// that branch is there too.
    var baseBranch: String?
    /// The workflow files GitHub would run, sorted. Nil without a checkout:
    /// the form then asks for a name.
    var workflowFiles: [String]?
    /// Where `workflowFiles` come from: the base branch as the checkout
    /// last fetched it (`origin/main`), else nil for the checkout's files.
    var workflowsRef: String?

    static let noGitHubRemote = "no github.com remote"

    /// Runs git in every folder: call it off the main thread. `repository`
    /// and `baseBranch` are the saved ones, if any: the checkout comes from
    /// a folder of that repository, and the workflow files from
    /// that branch.
    static func read(
        workspaceFolders: [String], repository saved: String?, baseBranch savedBase: String? = nil,
        gitPath: String = "/usr/bin/git"
    ) -> BoardConfigSuggestions {
        var seen = Set<String>()
        let folders = workspaceFolders
            .filter { seen.insert(URL(fileURLWithPath: $0).standardizedFileURL.path).inserted }
            .compactMap { folder(at: $0, gitPath: gitPath) }
        var suggestions = combine(folders, repository: saved)
        guard let folder = checkoutFolder(folders, repository: saved ?? suggestions.repository) else { return suggestions }
        suggestions.baseBranch = defaultBranch(of: folder.remote, at: folder.checkout, gitPath: gitPath)
        if let base = savedBase ?? suggestions.baseBranch,
           let files = workflowFiles(atRef: "refs/remotes/\(folder.remote)/\(base)", in: folder.checkout, gitPath: gitPath) {
            suggestions.workflowFiles = files
            suggestions.workflowsRef = "\(folder.remote)/\(base)"
        } else {
            suggestions.workflowFiles = workflowFiles(in: folder.checkout)
        }
        return suggestions
    }

    /// The suggested repository, and the checkout to read: the first folder
    /// pushing to `saved`, else to the suggested repository. GitHub ignores
    /// case, and so does the comparison.
    static func combine(_ folders: [Folder], repository saved: String?) -> BoardConfigSuggestions {
        let repositories = folders.map(\.repository)
        let source: RepositorySource
        var repository: String?
        if folders.isEmpty {
            source = .noRepository
        } else if let first = repositories.first, let shared = first,
                  repositories.allSatisfy({ $0?.lowercased() == shared.lowercased() }) {
            source = .shared
            repository = shared
        } else {
            var listed: [String] = []
            for name in repositories.map({ $0 ?? noGitHubRemote })
            where !listed.contains(where: { $0.lowercased() == name.lowercased() }) {
                listed.append(name)
            }
            source = .differing(listed)
        }
        let checkout = checkoutFolder(folders, repository: saved ?? repository)?.checkout
        return BoardConfigSuggestions(repository: repository, source: source, checkout: checkout)
    }

    /// The first folder pushing to `repository`.
    private static func checkoutFolder(_ folders: [Folder], repository: String?) -> Folder? {
        guard let wanted = repository?.lowercased() else { return nil }
        return folders.first { $0.repository?.lowercased() == wanted }
    }

    /// Nil outside a git repository (or a folder that's gone). A git dir
    /// (a bare repository's, or one apart from its checkout) is its own
    /// top level. The repository is where its pull requests live, whatever
    /// branch is checked out (`GitHubBaseRemote`), as the board reads it.
    static func folder(
        at path: String, gitPath: String = "/usr/bin/git",
        resolveAlias: (String) -> Bool? = { SSHHostAlias.resolve($0) }
    ) -> Folder? {
        let git = { (arguments: [String]) in
            GitCommand.output(arguments, cwd: path, gitPath: gitPath, timeout: 10)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let checkoutTop = git(["rev-parse", "--show-toplevel"]).flatMap { $0.isEmpty ? nil : $0 }
        guard let topLevel = checkoutTop ?? (git(["rev-parse", "--is-inside-git-dir"]) == "true" ? path : nil)
        else { return nil }
        let repository: String?
        let remote: String
        switch GitHubBaseRemote.read(at: path, gitPath: gitPath, resolveAlias: resolveAlias) {
        case .gitHub(let name, let from): (repository, remote) = (name, from)
        case .notGitHub(_, let from): (repository, remote) = (nil, from)
        case .noRemote, .notARepository, .unread: (repository, remote) = (nil, "origin")
        }
        let checkout = GitCommand.output(["worktree", "list", "--porcelain", "-z"], cwd: path, gitPath: gitPath, timeout: 10)
            .flatMap(mainWorkingTree(inListing:)) ?? topLevel
        return Folder(repository: repository, remote: remote, checkout: checkout)
    }

    /// `owner/name` of a github.com remote URL, spelled as in the URL
    /// (`GitHubRepository` lowercases it).
    static func repositoryName(remoteURL: String) -> String? {
        guard GitHubRepository(remoteURL: remoteURL)?.host == "github.com" else { return nil }
        return spelledOwnerAndName(remoteURL: remoteURL)
    }

    /// `owner/name` of a remote URL on any host, spelled as in the URL.
    static func spelledOwnerAndName(remoteURL: String) -> String? {
        guard let parsed = GitHubRepository(remoteURL: remoteURL) else { return nil }
        let components = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0 == "/" || $0 == ":" })
        guard components.count >= 2 else { return nil }
        let owner = String(components[components.count - 2])
        var name = String(components[components.count - 1])
        if name.lowercased().hasSuffix(".git") { name.removeLast(4) }
        guard owner.lowercased() == parsed.owner, name.lowercased() == parsed.name else {
            return "\(parsed.owner)/\(parsed.name)"
        }
        return "\(owner)/\(name)"
    }

    /// `ssh://…`, or scp-like `user@host:path`, which ssh resolves through
    /// its config; not `https://`.
    static func isSSH(_ remoteURL: String) -> Bool {
        let trimmed = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if let scheme = URL(string: trimmed)?.scheme?.lowercased(), trimmed.contains("://") {
            return scheme == "ssh" || scheme == "git+ssh" || scheme == "ssh+git"
        }
        guard let colon = trimmed.firstIndex(of: ":") else { return false }
        return !trimmed[..<colon].contains("/")
    }

    /// The first entry of `git worktree list --porcelain -z`, unless it is
    /// a bare repository, which has no files.
    static func mainWorkingTree(inListing listing: String) -> String? {
        let fields = listing.split(separator: "\0", omittingEmptySubsequences: false)
        guard let first = fields.first, first.hasPrefix("worktree ") else { return nil }
        let entry = fields.prefix { !$0.isEmpty }
        return entry.contains("bare") ? nil : String(first.dropFirst("worktree ".count))
    }

    /// The branch `refs/remotes/<remote>/HEAD` points to. Nil when it isn't
    /// set (a clone made with `git init` and `fetch`, say), or points to a
    /// branch that's gone (the default moved from master to main): the user
    /// types it.
    static func defaultBranch(of remote: String, at checkout: String, gitPath: String = "/usr/bin/git") -> String? {
        let git = { (arguments: [String]) in
            GitCommand.output(arguments, cwd: checkout, gitPath: gitPath, timeout: 10)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // The full name: `--short` can print `remotes/origin/main` when a
        // branch or tag is named `origin/main`.
        let prefix = "refs/remotes/\(remote)/"
        guard let target = git(["symbolic-ref", "--quiet", "refs/remotes/\(remote)/HEAD"]),
              target.hasPrefix(prefix), target.count > prefix.count,
              git(["rev-parse", "--verify", "--quiet", target + "^{commit}"]) != nil
        else { return nil }
        return String(target.dropFirst(prefix.count))
    }

    /// The workflow files in `.github/workflows` of `ref`'s tree. Nil when
    /// `ref` isn't there.
    static func workflowFiles(atRef ref: String, in checkout: String, gitPath: String = "/usr/bin/git") -> [String]? {
        guard let listing = GitCommand.output(
            ["ls-tree", "-z", ref, "--", ".github/workflows/"], cwd: checkout, gitPath: gitPath, timeout: 10
        ) else { return nil }
        // `<mode> <type> <object>\t<path>`
        return listing.split(separator: "\0").compactMap { entry -> String? in
            guard let tab = entry.firstIndex(of: "\t") else { return nil }
            let fields = entry[..<tab].split(separator: " ")
            let name = String(entry[entry.index(after: tab)...].split(separator: "/").last ?? "")
            return fields.count == 3 && fields[1] == "blob" && BoardConfig.isValidWorkflowFile(name) ? name : nil
        }.sorted()
    }

    /// The workflow files GitHub runs, in the checkout's own files: `.yml`
    /// and `.yaml` files directly in `.github/workflows`.
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
