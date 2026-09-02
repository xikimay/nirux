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
    let head: String?
    let isDirty: Bool

    init(repositoryRoot: String, head: String?, isDirty: Bool = false) {
        self.repositoryRoot = repositoryRoot
        self.head = head
        self.isDirty = isDirty
    }
}

enum UpstreamRepositoryObservation: Hashable, Sendable {
    case repository(GitHubRepository)
    case absent
    case failure

    var repository: GitHubRepository? {
        guard case .repository(let repository) = self else { return nil }
        return repository
    }
}

struct GitContext: Hashable, Sendable {
    let branch: String
    let identity: GitIdentity
    let upstreamRepositoryObservation: UpstreamRepositoryObservation
    var upstreamRepository: GitHubRepository? { upstreamRepositoryObservation.repository }

    init(
        branch: String,
        identity: GitIdentity,
        upstreamRepository: GitHubRepository? = nil
    ) {
        self.branch = branch
        self.identity = identity
        self.upstreamRepositoryObservation = upstreamRepository.map {
            .repository($0)
        } ?? .absent
    }

    init(
        branch: String,
        identity: GitIdentity,
        upstreamRepositoryObservation: UpstreamRepositoryObservation
    ) {
        self.branch = branch
        self.identity = identity
        self.upstreamRepositoryObservation = upstreamRepositoryObservation
    }
}

enum GitContextDetectionResult: Equatable, Sendable {
    case observed(GitContext)
    case notRepository
    case failure
}

enum GitDetect {
    static func context(at path: String) -> GitContext? {
        guard case .observed(let context) = observe(at: path) else { return nil }
        return context
    }

    static func observe(
        at path: String,
        gitPath: String = "/usr/bin/git",
        timeout: TimeInterval = 30
    ) -> GitContextDetectionResult {
        let workingDirectory = URL(fileURLWithPath: path).standardizedFileURL.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: workingDirectory,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else { return .failure }

        guard let rootResult = gitOutput(
            arguments: ["rev-parse", "--show-toplevel"],
            at: workingDirectory,
            gitPath: gitPath,
            timeout: timeout
        ) else { return .failure }
        guard rootResult.terminationStatus == 0 else {
            return containsGitMetadata(at: workingDirectory) ? .failure : .notRepository
        }
        let repositoryRoot = rootResult.standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !repositoryRoot.isEmpty else { return .failure }

        guard let branchResult = gitOutput(
            arguments: ["symbolic-ref", "--quiet", "--short", "HEAD"],
            at: workingDirectory,
            gitPath: gitPath,
            timeout: timeout
        ) else { return .failure }
        let branch: String
        if branchResult.terminationStatus == 0 {
            branch = branchResult.standardOutput
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !branch.isEmpty else { return .failure }
        } else if branchResult.terminationStatus == 1 {
            branch = "HEAD"
        } else {
            return .failure
        }

        guard let headResult = gitOutput(
            arguments: ["rev-parse", "--verify", "HEAD"],
            at: workingDirectory,
            gitPath: gitPath,
            timeout: timeout
        ) else { return .failure }
        let head: String?
        if headResult.terminationStatus == 0 {
            let resolvedHead = headResult.standardOutput
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !resolvedHead.isEmpty else { return .failure }
            head = resolvedHead
        } else {
            guard branch != "HEAD",
                  let branchReference = gitOutput(
                      arguments: ["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"],
                      at: workingDirectory,
                      gitPath: gitPath,
                      timeout: timeout
                  ), branchReference.terminationStatus == 1
            else { return .failure }
            head = nil
        }

        guard let status = gitOutput(
            arguments: ["status", "--porcelain=v1", "--untracked-files=normal"],
            at: workingDirectory,
            gitPath: gitPath,
            timeout: timeout
        ), status.terminationStatus == 0 else { return .failure }
        let canonicalRepositoryRoot = URL(
            fileURLWithPath: repositoryRoot
        ).standardizedFileURL.path
        return .observed(GitContext(
            branch: branch,
            identity: GitIdentity(
                repositoryRoot: canonicalRepositoryRoot,
                head: head,
                isDirty: !status.standardOutput.isEmpty
            ),
            upstreamRepositoryObservation: upstreamRepositoryObservation(
                at: canonicalRepositoryRoot,
                branch: branch,
                gitPath: gitPath,
                timeout: timeout
            )
        ))
    }

    static func upstreamRepositoryObservation(
        at repositoryRoot: String,
        branch: String,
        gitPath: String = "/usr/bin/git",
        timeout: TimeInterval = 30
    ) -> UpstreamRepositoryObservation {
        guard let remoteResult = gitOutput(
            arguments: ["for-each-ref", "--format=%(push:remotename)", "refs/heads/\(branch)"],
            at: repositoryRoot,
            gitPath: gitPath,
            timeout: timeout
        ) else { return .failure }
        guard remoteResult.terminationStatus == 0 else { return .failure }
        let remote = remoteResult.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remote.isEmpty, remote != "." else { return .absent }
        guard let remoteURLResult = gitOutput(
            arguments: ["remote", "get-url", "--push", remote],
            at: repositoryRoot,
            gitPath: gitPath,
            timeout: timeout
        ) else { return .failure }
        guard remoteURLResult.terminationStatus == 0 else { return .failure }
        guard let repository = GitHubRepository(remoteURL: remoteURLResult.standardOutput)
        else { return .absent }
        return .repository(repository)
    }

    static func contextAsync(
        at path: String,
        completion: @escaping @MainActor @Sendable (GitContextDetectionResult) -> Void
    ) {
        DispatchQueue.global(qos: .utility).async {
            let result = observe(at: path)
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    private struct CommandOutput {
        let standardOutput: String
        let terminationStatus: Int32
    }

    private static func gitOutput(
        arguments: [String],
        at path: String,
        gitPath: String,
        timeout: TimeInterval
    ) -> CommandOutput? {
        guard let result = BoundedProcess.run(
            executableURL: URL(fileURLWithPath: gitPath),
            arguments: arguments,
            currentDirectoryURL: URL(fileURLWithPath: path),
            timeout: timeout
        ), let output = String(data: result.standardOutput, encoding: .utf8)
        else { return nil }
        return CommandOutput(
            standardOutput: output,
            terminationStatus: result.terminationStatus
        )
    }

    private static func containsGitMetadata(at path: String) -> Bool {
        var directory = URL(fileURLWithPath: path).standardizedFileURL
        while true {
            if FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(".git").path
            ) {
                return true
            }
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else { return false }
            directory = parent
        }
    }
}
