import Foundation

/// Where a repository's pull requests live, whatever branch is checked
/// out: the GitHub repository gh takes as its base without being told. The
/// remote `gh repo set-default` marked (`remote.<name>.gh-resolved`), else
/// the first of upstream, github, origin, then the others by name, as gh
/// sorts them, whose URL is on github.com (or an SSH alias ssh resolves
/// to it). The board's unsaved sections read it and Board Settings
/// suggests it, so saving as suggested keeps what the board showed; the
/// General tab of Space Settings names it.
enum GitHubBaseRemote {
    enum Read: Equatable, Sendable {
        /// `owner/name` as the URL spells it, and the remote it came from.
        case gitHub(repository: String, remote: String)
        /// The repository has no remote.
        case noRemote
        /// No remote is on github.com: the first one's host (nil for a
        /// path), which may be an SSH alias ssh doesn't resolve to it.
        case notGitHub(host: String?, remote: String)
        /// The folder is gone, or no longer in a git repository.
        case notARepository
        /// git, or ssh, didn't answer in time.
        case unread
    }

    /// One git call, plus ssh for an SSH host other than github.com (once
    /// it says yes, never again): never on the main thread.
    /// `resolveAlias` says whether an SSH host stands for github.com, nil
    /// when it couldn't tell; tests answer in its place.
    static func read(
        at folder: String,
        gitPath: String = "/usr/bin/git",
        resolveAlias: (String) -> Bool? = { SSHHostAlias.resolve($0) }
    ) -> Read {
        guard FileManager.default.fileExists(atPath: folder) else { return .notARepository }
        let config = WorktreeCleanup.git(
            ["config", "--local", "--get-regexp", #"^remote\..*\.(url|gh-resolved)$"#],
            in: folder, tools: WorktreeCleanup.Tools(gitPath: gitPath), timeout: 10
        )
        switch config.status {
        case 0: break
        // git config's status when nothing matches.
        case 1: return .noRemote
        // Outside a repository, `--local` refuses.
        case 128: return .notARepository
        default: return .unread
        }
        let remotes = Self.remotes(inConfig: config.stdout)
        guard let first = remotes.first else { return .noRemote }
        var couldNotTell = false
        for remote in remotes {
            switch Self.repository(of: remote.url, resolveAlias: resolveAlias) {
            case .some(.some(let repository)): return .gitHub(repository: repository, remote: remote.name)
            case .some(.none): continue
            case .none: couldNotTell = true
            }
        }
        return couldNotTell
            ? .unread
            : .notGitHub(host: GitHubRepository(remoteURL: first.url)?.host, remote: first.name)
    }

    struct Remote: Equatable {
        let name: String
        let url: String
    }

    /// The remotes with a URL in `git config --get-regexp` output, in the
    /// order gh tries them: the one marked as gh's base, then upstream,
    /// github, origin, then the others by name.
    static func remotes(inConfig output: String) -> [Remote] {
        var urls: [String: String] = [:]
        var marked: Set<String> = []
        for line in output.split(separator: "\n") {
            guard let space = line.firstIndex(of: " ") else { continue }
            let key = line[..<space]
            let value = line[line.index(after: space)...].trimmingCharacters(in: .whitespaces)
            guard key.hasPrefix("remote.") else { continue }
            let rest = key.dropFirst("remote.".count)
            if rest.hasSuffix(".url") {
                urls[String(rest.dropLast(".url".count))] = value
            } else if rest.hasSuffix(".gh-resolved"), value == "base" {
                marked.insert(String(rest.dropLast(".gh-resolved".count)))
            }
        }
        let rank = { (name: String) -> Int in
            if marked.contains(name) { return 4 }
            switch name.lowercased() {
            case "upstream": return 3
            case "github": return 2
            case "origin": return 1
            default: return 0
            }
        }
        return urls.map { Remote(name: $0.key, url: $0.value) }
            .sorted { (rank($0.name), $1.name) > (rank($1.name), $0.name) }
    }

    /// `owner/name` when `url` is a github.com repository; `.some(nil)`
    /// when it isn't; nil when ssh couldn't tell for an alias.
    private static func repository(of url: String, resolveAlias: (String) -> Bool?) -> String?? {
        guard let parsed = GitHubRepository(remoteURL: url) else { return .some(nil) }
        if parsed.host != "github.com" {
            guard BoardConfigSuggestions.isSSH(url) else { return .some(nil) }
            switch resolveAlias(parsed.host) {
            case nil: return nil
            case false?: return .some(nil)
            case true?: break
            }
        }
        return .some(BoardConfigSuggestions.spelledOwnerAndName(remoteURL: url))
    }
}
