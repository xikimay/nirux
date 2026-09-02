import Foundation

struct GitHubRepository: Hashable, Sendable {
    let host: String
    let owner: String
    let name: String

    init(host: String = "github.com", owner: String, name: String) {
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

    private static func normalizedHost(_ host: String) -> String {
        let normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            .lowercased()
        return normalized == "ssh.github.com" ? "github.com" : normalized
    }
}

struct GitIdentity: Hashable, Sendable {
    let repositoryRoot: String
    let head: String
    let isDirty: Bool

    init(repositoryRoot: String, head: String, isDirty: Bool = false) {
        self.repositoryRoot = repositoryRoot
        self.head = head
        self.isDirty = isDirty
    }
}

struct GitContext: Hashable, Sendable {
    let branch: String
    let identity: GitIdentity
    let upstreamRepository: GitHubRepository?

    init(
        branch: String,
        identity: GitIdentity,
        upstreamRepository: GitHubRepository? = nil
    ) {
        self.branch = branch
        self.identity = identity
        self.upstreamRepository = upstreamRepository
    }
}

enum GitDetect {
    static func context(at path: String) -> GitContext? {
        guard let output = gitOutput(
            arguments: ["rev-parse", "--show-toplevel", "HEAD", "--abbrev-ref", "HEAD"],
            at: path
        ), let status = gitOutput(
            arguments: ["status", "--porcelain=v1", "--untracked-files=normal"],
            at: path
        ) else { return nil }
        let lines = output
            .split(whereSeparator: { $0.isNewline })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard lines.count == 3,
              lines.allSatisfy({ !$0.isEmpty })
        else { return nil }
        let repositoryRoot = URL(fileURLWithPath: lines[0]).standardizedFileURL.path
        let branch = lines[2]
        return GitContext(
            branch: branch,
            identity: GitIdentity(
                repositoryRoot: repositoryRoot,
                head: lines[1],
                isDirty: !status.isEmpty
            ),
            upstreamRepository: upstreamRepository(at: repositoryRoot, branch: branch)
        )
    }

    static func upstreamRepository(at repositoryRoot: String, branch: String) -> GitHubRepository? {
        guard let remote = gitOutput(
            arguments: ["for-each-ref", "--format=%(upstream:remotename)", "refs/heads/\(branch)"],
            at: repositoryRoot
        )?.trimmingCharacters(in: .whitespacesAndNewlines),
        !remote.isEmpty,
        let remoteURL = gitOutput(arguments: ["remote", "get-url", remote], at: repositoryRoot)
        else { return nil }
        return GitHubRepository(remoteURL: remoteURL)
    }

    static func contextAsync(
        at path: String,
        completion: @escaping @MainActor @Sendable (GitContext?) -> Void
    ) {
        DispatchQueue.global(qos: .utility).async {
            let result = context(at: path)
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    private static func gitOutput(arguments: [String], at path: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = arguments
        proc.currentDirectoryURL = URL(fileURLWithPath: path)

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}
