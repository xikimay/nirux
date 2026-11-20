import Foundation

/// "Once task A's pull request merges, do this" (docs/design/task-dependencies.md),
/// kept on the workspace it acts on and saved with it. A's pull request is
/// followed through its usual reads (`refreshPRInfo`); GitHub is asked once
/// more whenever they stop showing the one recorded, or A closes.
struct MergeWait: Codable, Equatable, Sendable {
    let id: String
    var awaited: Awaited
    let action: Action
    let createdAt: TimeInterval

    /// The task whose pull request must merge, as last seen: what names it,
    /// and where GitHub is asked, once it is gone.
    struct Awaited: Codable, Equatable, Sendable {
        let workspaceID: String
        var title: String
        var branch: String?
        /// A folder of its repository that outlives the task (the space's
        /// anchor): where gh looks the branch up.
        var repository: String?
        /// Its pull request, last read open.
        var pullRequest: PullRequest?
    }

    struct PullRequest: Codable, Equatable, Sendable {
        let number: Int
        let url: String
    }

    enum Action: Codable, Equatable, Sendable {
        /// Typed into the workspace's agent as the Lead's `tell`.
        case tell(message: String)
    }

    /// A pull request as `gh pr view` gives it.
    struct LookedUp: Equatable, Sendable {
        let number: Int
        let state: String
        let url: String
    }

    enum Reading: Equatable, Sendable {
        /// A read of the awaited task's pull request; nil: it found none.
        case read(PRInfo?)
        /// The awaited task closed.
        case gone
        /// What GitHub said of the recorded pull request, or the branch's;
        /// nil: none.
        case lookedUp(LookedUp?, awaitedGone: Bool)
        /// GitHub didn't answer.
        case unanswered(String, awaitedGone: Bool)
    }

    enum Failure: Equatable, Sendable {
        case closedUnmerged(number: Int)
        /// The task closed first, with its pull request still open, if any.
        case closedFirst(number: Int?)
        /// The task closed, and GitHub couldn't say whether it merged.
        case unanswered(String)
    }

    enum Step: Equatable, Sendable {
        case keep, release, lookUp
        case fail(Failure)
    }

    /// What a reading means for the wait. The pull request read open or
    /// merged, or looked up, is recorded.
    mutating func step(after reading: Reading) -> Step {
        switch reading {
        case .read(let info?):
            switch info.state.uppercased() {
            case "OPEN":
                awaited.pullRequest = PullRequest(number: info.number, url: info.url)
                return .keep
            case "MERGED":
                awaited.pullRequest = PullRequest(number: info.number, url: info.url)
                return .release
            case "CLOSED" where awaited.pullRequest.map({ $0.url == info.url }) ?? true:
                return .fail(.closedUnmerged(number: info.number))
            default:
                return lookUpTarget == nil ? .keep : .lookUp
            }
        case .read(nil):
            return lookUpTarget == nil ? .keep : .lookUp
        case .gone:
            return lookUpTarget == nil ? .fail(.closedFirst(number: nil)) : .lookUp
        case .lookedUp(let found?, let awaitedGone):
            awaited.pullRequest = PullRequest(number: found.number, url: found.url)
            switch found.state.uppercased() {
            case "MERGED":
                return .release
            case "CLOSED":
                return .fail(.closedUnmerged(number: found.number))
            default:
                return awaitedGone ? .fail(.closedFirst(number: found.number)) : .keep
            }
        case .lookedUp(nil, let awaitedGone):
            return awaitedGone ? .fail(.closedFirst(number: nil)) : .keep
        case .unanswered(let reason, let awaitedGone):
            return awaitedGone ? .fail(.unanswered(reason)) : .keep
        }
    }

    // MARK: - Looking it up

    /// What `gh pr view` is given, and where it runs.
    struct LookUpTarget: Equatable, Sendable {
        /// The pull request's URL, else the branch.
        let pullRequest: String
        let folder: String?
    }

    var lookUpTarget: LookUpTarget? {
        if let pullRequest = awaited.pullRequest { return LookUpTarget(pullRequest: pullRequest.url, folder: awaited.repository) }
        guard let branch = awaited.branch, let repository = awaited.repository else { return nil }
        return LookUpTarget(pullRequest: branch, folder: repository)
    }

    /// The pull request `target` names, nil when its branch has none, or why
    /// GitHub couldn't say. Runs gh: call it off the main thread.
    static func lookUp(_ target: LookUpTarget) -> Result<LookedUp?, LookUpFailure> {
        guard let ghPath = PRDetect.installedGHPath() else {
            return .failure(LookUpFailure(reason: "the GitHub CLI (gh) isn't installed"))
        }
        let folder = target.folder.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil } ?? NSHomeDirectory()
        guard let result = BoundedProcess.run(
            executableURL: URL(fileURLWithPath: ghPath),
            arguments: ["pr", "view", target.pullRequest, "--json", "number,state,url"],
            currentDirectoryURL: URL(fileURLWithPath: folder),
            timeout: 30
        ) else { return .failure(LookUpFailure(reason: "gh didn't answer")) }
        let errors = String(decoding: result.standardError, as: UTF8.self)
        if result.terminationStatus != 0 {
            if errors.lowercased().contains("no pull requests found") { return .success(nil) }
            let line = errors.split(whereSeparator: \.isNewline).first.map(String.init) ?? "exit \(result.terminationStatus)"
            return .failure(LookUpFailure(reason: "gh: \(line)"))
        }
        guard let json = try? JSONSerialization.jsonObject(with: result.standardOutput) as? [String: Any],
              let number = json["number"] as? Int, let state = json["state"] as? String, let url = json["url"] as? String
        else { return .failure(LookUpFailure(reason: "gh gave an answer Nirux couldn't read")) }
        return .success(LookedUp(number: number, state: state, url: url))
    }

    struct LookUpFailure: Error, Equatable, Sendable {
        let reason: String
    }

    // MARK: - Words

    /// "#651", or "“Fix login”" before it has a pull request.
    var awaitedName: String {
        awaited.pullRequest.map { "#\($0.number)" } ?? "“\(MissionPromptText.quoted(awaited.title))”"
    }

    /// "#651 (“Fix login”)", or "“Fix login”".
    var awaitedLongName: String {
        let title = "“\(MissionPromptText.quoted(awaited.title))”"
        return awaited.pullRequest.map { "#\($0.number) (\(title))" } ?? title
    }

    /// Why it won't happen, as a sentence's start.
    func sentence(_ failure: Failure) -> String {
        let title = "“\(MissionPromptText.quoted(awaited.title))”"
        switch failure {
        case .closedUnmerged(let number): return "#\(number) (\(title)) closed without merging"
        case .closedFirst(let number?): return "\(title) closed while #\(number) was still open"
        case .closedFirst(nil): return "\(title) closed without a merged pull request"
        case .unanswered(let reason): return "\(title) closed, and GitHub couldn't say whether it merged (\(reason))"
        }
    }

    /// How much of a held message notices quote.
    static let quotedLength = 200

    /// How often GitHub is asked again while reads keep saying the same
    /// (no pull request, say, where it has one under another branch name).
    static let lookUpInterval: TimeInterval = 600
}
