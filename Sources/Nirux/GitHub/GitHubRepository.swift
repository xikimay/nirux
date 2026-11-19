import Foundation

struct GitHubRepository: Hashable, Sendable {
    let host: String
    let owner: String
    let name: String

    init(host: String = GitHub.host, owner: String, name: String) {
        self.host = Self.normalizedHost(host)
        self.owner = owner.lowercased()
        self.name = name.lowercased()
    }

    init?(remoteURL: String) {
        let trimmed = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let host: String
        let path: String
        if let url = URL(string: trimmed), url.scheme != nil,
           let parsedHost = url.host, !parsedHost.isEmpty {
            host = parsedHost
            path = url.path
        } else if let colon = trimmed.firstIndex(of: ":"),
                  !trimmed[..<colon].contains("/") {
            let authority = trimmed[..<colon]
            guard let parsedHost = authority.split(separator: "@").last,
                  !parsedHost.isEmpty
            else { return nil }
            host = String(parsedHost)
            path = String(trimmed[trimmed.index(after: colon)...])
        } else {
            return nil
        }

        let components = path.split(separator: "/")
        guard components.count >= 2 else { return nil }
        let owner = String(components[components.count - 2])
        var name = String(components[components.count - 1])
        if name.lowercased().hasSuffix(".git") {
            name.removeLast(4)
        }
        guard !owner.isEmpty, !name.isEmpty else { return nil }
        self.init(host: host, owner: owner, name: name)
    }

    init?(repositoryURL: String, owner: String, name: String) {
        guard let url = URL(string: repositoryURL),
              let host = url.host, !host.isEmpty,
              !owner.isEmpty, !name.isEmpty
        else { return nil }
        self.init(host: host, owner: owner, name: name)
    }

    static func normalizedHost(_ host: String) -> String {
        let normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            .lowercased()
        return normalized == "ssh.github.com" ? GitHub.host : normalized
    }
}

extension GitHubRepository {
    /// `owner/name`, lowercased as compared.
    var ownerAndName: String { "\(owner)/\(name)" }

    /// The same repository whatever host spells it: an SSH host alias
    /// (`git@github-work:…`) points at github.com all the same.
    func hasOwnerAndName(of other: GitHubRepository) -> Bool {
        owner == other.owner && name == other.name
    }

    /// `owner/name` as board.json and a saved queue spell it, on
    /// github.com; nil for anything `isValid(ownerAndName:)` refuses.
    init?(ownerAndName value: String) {
        guard Self.isValid(ownerAndName: value) else { return nil }
        let parts = value.split(separator: "/")
        self.init(owner: String(parts[0]), name: String(parts[1]))
    }

    /// `owner/name` with GitHub's characters: an owner of 1 to 39 letters,
    /// digits, hyphens and underscores (managed users' accounts), not
    /// starting with a hyphen; a name of 1 to 100 letters, digits, `.`, `-`
    /// and `_`, other than `.` and `..`, not ending in `.git`.
    static func isValid(ownerAndName value: String) -> Bool {
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

    /// The repository of a pull request's address, its host included:
    /// "https://github.com/owner/name/pull/52".
    init?(pullRequestURL address: String) {
        guard let url = URL(string: address), let host = url.host else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 4, parts[2] == "pull" else { return nil }
        self.init(host: host, owner: parts[0], name: parts[1])
    }

    /// `owner/name` of a github.com remote URL, spelled as in the URL.
    static func gitHubOwnerAndName(remoteURL: String) -> String? {
        guard GitHubRepository(remoteURL: remoteURL)?.host == GitHub.host else { return nil }
        return spelledOwnerAndName(remoteURL: remoteURL)
    }

    /// `owner/name` of a remote URL on any host, spelled as in the URL
    /// (`GitHubRepository` lowercases it).
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
}
