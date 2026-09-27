import Foundation

/// The Project Board's settings for one project (a space): the GitHub
/// repository its merge queue works on and the rules the queue follows.
/// `BoardConfigStore` keeps them in `<state dir>/projects/<space id>/board.json`.
/// See docs/project-board.md, section 5.
///
/// Values stay as read, even invalid ones (an empty check name, a timeout
/// of 0), so writing the config back loses nothing. `problems` lists them.
/// The merge queue starts only through `BoardConfigStore.Loaded`, whose
/// `queueSettings` also refuses a file this build must not write.
struct BoardConfig: Equatable, Sendable {
    static let schemaVersion = 1
    static let defaultRequiredChecks = ["test"]
    static let defaultTimeoutMinutes = 30
    static let timeoutRange = 1...240

    /// Never `rebase`: a rebase merge's last commit doesn't have the base
    /// tip as its first parent, so the queue couldn't check that a merge
    /// landed on the base it tested.
    enum MergeMethod: String, CaseIterable, Sendable {
        case merge
        case squash
    }

    /// What the queue waits for after each merge before merging the next PR.
    enum PostMergeWorkflow: Equatable, Sendable {
        /// Not chosen yet. The queue refuses to start: it never guesses.
        case unset
        /// `"none"` in the file: merge the next PR right after a merge.
        case noWorkflow
        /// A file in `.github/workflows`, such as `nightly.yml`.
        case workflow(String)

        /// The JSON value: absent when unset.
        var storedValue: String? {
            switch self {
            case .unset: return nil
            case .noWorkflow: return "none"
            case .workflow(let file): return file
            }
        }

        init(storedValue: String?) {
            switch storedValue {
            case nil, "": self = .unset
            case "none": self = .noWorkflow
            case let file?: self = .workflow(file)
            }
        }
    }

    /// `owner/name` on github.com, as typed or as the remote spells it. Nil
    /// when not set. GitHub ignores case: compare `gitHubRepository`.
    var repository: String?
    /// The branch pull requests merge into. Nil when not set.
    var baseBranch: String?
    /// Check run names, or `Workflow / job`, that must be green before a merge.
    var requiredChecks: [String] = BoardConfig.defaultRequiredChecks
    var postMergeWorkflow: PostMergeWorkflow = .unset
    var mergeMethod: MergeMethod = .merge
    var checksTimeoutMinutes = BoardConfig.defaultTimeoutMinutes
    var postMergeTimeoutMinutes = BoardConfig.defaultTimeoutMinutes

    /// What the merge queue runs with: every value set and valid. Made by
    /// `BoardConfigStore.Loaded.queueSettings` only.
    struct QueueSettings: Equatable, Sendable {
        /// As saved, for `gh --repo` and display.
        let repository: String
        /// For comparisons: one queue per repository, a PR's head repository.
        let gitHubRepository: GitHubRepository
        let baseBranch: String
        let requiredChecks: [String]
        /// The workflow file to wait for after each merge. Nil: merge the
        /// next PR right away.
        let postMergeWorkflow: String?
        let mergeMethod: MergeMethod
        let checksTimeoutMinutes: Int
        let postMergeTimeoutMinutes: Int
    }

    // MARK: - Validation

    /// What Save refuses, in the form's order. Empty when the values can be
    /// saved. An unset post-merge workflow isn't one: it stays unset until
    /// the user picks a file or None.
    var problems: [String] {
        var problems: [String] = []
        if let repository {
            if !Self.isValidRepository(repository) {
                problems.append("The repository must be owner/name, as on github.com: “\(repository)” isn’t.")
            }
        } else {
            problems.append("Set the repository (owner/name).")
        }
        if let baseBranch {
            if !Self.isValidBranchName(baseBranch) {
                problems.append("“\(baseBranch)” isn’t a valid branch name.")
            }
        } else {
            problems.append("Set the base branch.")
        }
        if requiredChecks.isEmpty {
            problems.append("Add at least one required check.")
        } else if requiredChecks.contains(where: { !Self.isValidCheckName($0) }) {
            problems.append("A required check is empty, or holds a tab or a line break.")
        }
        if case .workflow(let file) = postMergeWorkflow, !Self.isValidWorkflowFile(file) {
            problems.append("The post-merge workflow must be a .yml or .yaml file name, such as nightly.yml.")
        }
        if !Self.timeoutRange.contains(checksTimeoutMinutes) || !Self.timeoutRange.contains(postMergeTimeoutMinutes) {
            problems.append(
                "Timeouts must be between \(Self.timeoutRange.lowerBound) and \(Self.timeoutRange.upperBound) minutes."
            )
        }
        return problems
    }

    /// The repository to compare with others (lowercased, on github.com).
    /// Nil unless `repository` is valid.
    var gitHubRepository: GitHubRepository? {
        guard let repository, Self.isValidRepository(repository) else { return nil }
        let parts = repository.split(separator: "/")
        return GitHubRepository(owner: String(parts[0]), name: String(parts[1]))
    }

    /// `owner/name` with GitHub's characters: an owner of 1 to 39 letters,
    /// digits, hyphens and underscores (managed users' accounts), not
    /// starting with a hyphen; a name of 1 to 100 letters, digits, `.`, `-`
    /// and `_`, other than `.` and `..`, not ending in `.git`.
    static func isValidRepository(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let owner = parts[0].unicodeScalars
        let name = parts[1].unicodeScalars
        let isASCIIAlphanumeric = { (scalar: Unicode.Scalar) in
            scalar.isASCII && CharacterSet.alphanumerics.contains(scalar)
        }
        guard (1...39).contains(owner.count), owner.first != "-",
              owner.allSatisfy({ isASCIIAlphanumeric($0) || $0 == "-" || $0 == "_" })
        else { return false }
        return (1...100).contains(name.count) && parts[1] != "." && parts[1] != ".."
            && !parts[1].lowercased().hasSuffix(".git")
            && name.allSatisfy { isASCIIAlphanumeric($0) || "._-".unicodeScalars.contains($0) }
    }

    /// The rules of `git check-ref-format --branch`, plus no leading hyphen
    /// or plus sign (an option, a force refspec), no `HEAD` and no `refs/`:
    /// a plain branch name. It may hold `#` or `%`: percent-encode it in a
    /// REST path.
    static func isValidBranchName(_ name: String) -> Bool {
        guard !name.isEmpty, name != "@", name != "HEAD", !name.hasPrefix("-"), !name.hasPrefix("+"),
              !name.hasPrefix("refs/"), !name.hasPrefix("/"),
              !name.hasSuffix("/"), !name.hasSuffix("."), !name.hasSuffix(".lock"),
              !name.contains(".."), !name.contains("//"), !name.contains("@{")
        else { return false }
        let forbidden = " ~^:?*[\\".unicodeScalars
        guard !name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F || forbidden.contains($0) })
        else { return false }
        return !name.split(separator: "/").contains { $0.hasPrefix(".") || $0.hasSuffix(".lock") }
    }

    /// Not blank, and on one line: the form lists one check per line.
    static func isValidCheckName(_ name: String) -> Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !name.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F || CharacterSet.newlines.contains($0) }
    }

    /// A file name in `.github/workflows`: no folder, ending in `.yml` or
    /// `.yaml`, not starting with a hyphen.
    static func isValidWorkflowFile(_ file: String) -> Bool {
        let lowercased = file.lowercased()
        guard let suffix = [".yml", ".yaml"].first(where: { lowercased.hasSuffix($0) }),
              file.count > suffix.count, !file.hasPrefix("-"), !file.contains("/"), !file.contains("\\")
        else { return false }
        return !file.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }
}

// MARK: - Coding

extension BoardConfig: Codable {
    /// Never remove or rename a key: a file that has it would turn
    /// read-only (an unknown key). Changing what a key holds or means bumps
    /// `schemaVersion`, so older builds leave the file alone.
    enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case repository
        case baseBranch
        case requiredChecks
        case postMergeWorkflow
        case mergeMethod
        case checksTimeoutMinutes
        case postMergeTimeoutMinutes
    }

    /// Lenient: a missing or null key gets its default, and an empty string
    /// means not set. An unknown merge method reads as `merge`; the store
    /// then keeps the file read-only, so the queue won't run with it. Unknown
    /// keys and `schemaVersion` are the store's business too.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let nonEmpty = { (value: String?) in value?.isEmpty == false ? value : nil }
        repository = try nonEmpty(container.decodeIfPresent(String.self, forKey: .repository))
        baseBranch = try nonEmpty(container.decodeIfPresent(String.self, forKey: .baseBranch))
        requiredChecks = try container.decodeIfPresent([String].self, forKey: .requiredChecks)
            ?? Self.defaultRequiredChecks
        postMergeWorkflow = try PostMergeWorkflow(
            storedValue: container.decodeIfPresent(String.self, forKey: .postMergeWorkflow)
        )
        mergeMethod = try container.decodeIfPresent(String.self, forKey: .mergeMethod)
            .flatMap(MergeMethod.init(rawValue:)) ?? .merge
        checksTimeoutMinutes = try container.decodeIfPresent(Int.self, forKey: .checksTimeoutMinutes)
            ?? Self.defaultTimeoutMinutes
        postMergeTimeoutMinutes = try container.decodeIfPresent(Int.self, forKey: .postMergeTimeoutMinutes)
            ?? Self.defaultTimeoutMinutes
    }

    /// Keys that aren't set are left out.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.schemaVersion, forKey: .schemaVersion)
        try container.encodeIfPresent(repository, forKey: .repository)
        try container.encodeIfPresent(baseBranch, forKey: .baseBranch)
        try container.encode(requiredChecks, forKey: .requiredChecks)
        try container.encodeIfPresent(postMergeWorkflow.storedValue, forKey: .postMergeWorkflow)
        try container.encode(mergeMethod.rawValue, forKey: .mergeMethod)
        try container.encode(checksTimeoutMinutes, forKey: .checksTimeoutMinutes)
        try container.encode(postMergeTimeoutMinutes, forKey: .postMergeTimeoutMinutes)
    }
}
