import Foundation

/// "Once task A's pull request merges, do this" (docs/design/task-dependencies.md),
/// kept on the workspace it acts on and saved with it. A's pull request is
/// followed through its usual reads (`refreshPRInfo`); GitHub is asked about
/// the one recorded whenever reads stop showing it, or A closes.
struct MergeWait: Codable, Equatable, Sendable {
    let id: String
    var awaited: Awaited
    let action: Action
    let createdAt: TimeInterval
    /// When the merge was seen. A held message can be retried for `deliveryLifetime`.
    var mergedAt: TimeInterval?
    /// Why a waiting task didn't start: its row reads Needs you until the
    /// Lead or the user starts it, points it at another task, or closes it.
    var failure: String?

    /// A relaunch during creation asks the user to check this branch before retrying.
    var startingBranch: String?

    /// The task whose pull request must merge, as last seen.
    struct Awaited: Codable, Equatable, Sendable {
        let workspaceID: String
        var title: String
        /// The pull request read open first, or merged: the one that counts.
        var pullRequest: PullRequest?
    }

    struct PullRequest: Codable, Equatable, Sendable {
        let number: Int
        let url: String
    }

    enum Action: Codable, Equatable, Sendable {
        /// Typed into the workspace's agent as the Lead's `tell`.
        case tell(message: String)
        /// Starts the workspace, a waiting task (`start_task`'s `after`).
        case start(PendingStart)
    }

    /// What a waiting task starts with, as `start_task` got it.
    struct PendingStart: Codable, Equatable, Sendable {
        let description: String
        let repositoryKey: String
        let repository: String
        /// The template's name and text as they were.
        let template: TaskTemplates.Template?
        var options: NewTask.StartOptions? = nil

        var suggestedBranch: String {
            options?.branch ?? NewTask.suggestedBranch(description: description, title: options?.title, templateName: template?.name)
        }
    }

    /// The waiting task's start, when this is one.
    var pendingStart: PendingStart? {
        if case .start(let start) = action { return start }
        return nil
    }

    /// A pull request as GitHub gives it.
    struct LookedUp: Equatable, Sendable {
        let number: Int
        let state: GitHub.PullRequestState?
        let url: String
    }

    enum Reading: Equatable, Sendable {
        /// A read of the awaited task's pull request; nil: it found none.
        case read(PRInfo?)
        /// The awaited task closed.
        case gone
        /// What GitHub said of the recorded pull request (its URL may have
        /// changed since, with the repository's name), or, as the task
        /// closed, of a branch's that is the wait's; nil: none.
        case lookedUp(LookedUp?, awaitedGone: Bool)
        /// GitHub didn't answer, for the `attempt`th time in a row.
        case unanswered(String, awaitedGone: Bool, attempt: Int)
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

    /// What a reading means for the wait. Once a pull request is recorded,
    /// only it counts: a read of another one sends GitHub to the recorded
    /// one. A merged or failed wait is over: readings leave it.
    mutating func step(after reading: Reading) -> Step {
        guard mergedAt == nil, startingBranch == nil, failure == nil else { return .keep }
        switch reading {
        case .read(let info?):
            if let recorded = awaited.pullRequest, recorded.url != info.url { return .lookUp }
            return step(found: LookedUp(number: info.number, state: info.state, url: info.url), awaitedGone: false)
        case .read(nil):
            return awaited.pullRequest == nil ? .keep : .lookUp
        case .gone:
            return awaited.pullRequest == nil ? .fail(.closedFirst(number: nil)) : .lookUp
        case .lookedUp(let found?, let awaitedGone):
            return step(found: found, awaitedGone: awaitedGone)
        case .lookedUp(nil, let awaitedGone):
            return awaitedGone ? .fail(.closedFirst(number: nil)) : .keep
        case .unanswered(let reason, let awaitedGone, let attempt):
            return awaitedGone && attempt >= Self.maxUnansweredLookUps ? .fail(.unanswered(reason)) : .keep
        }
    }

    private mutating func step(found: LookedUp, awaitedGone: Bool) -> Step {
        switch found.state {
        case .open:
            awaited.pullRequest = PullRequest(number: found.number, url: found.url)
            return awaitedGone ? .fail(.closedFirst(number: found.number)) : .keep
        case .merged:
            awaited.pullRequest = PullRequest(number: found.number, url: found.url)
            return .release
        case .closed:
            return .fail(.closedUnmerged(number: found.number))
        case nil:
            return awaited.pullRequest == nil ? .keep : .lookUp
        }
    }

    /// Whether a message whose pull request merged at `mergedAt` is past
    /// trying at `now`.
    func isPastDelivery(at now: TimeInterval) -> Bool {
        mergedAt.map { now - $0 >= Self.deliveryLifetime } ?? false
    }

    // MARK: - Looking it up

    /// The pull request at `url`, nil when GitHub has none there, or why it
    /// couldn't say. Runs gh: call it off the main thread.
    static func lookUp(_ url: String) -> Result<LookedUp?, LookUpFailure> {
        let call = GitHub.CLI.Call(["pr", "view", url, "--json", "number,state,url"])
        let data: Data
        switch GitHub.CLI.run(call).flatMap(\.result) {
        case .success(let output): data = output
        case .failure(let failure):
            if failure.message.lowercased().contains("could not resolve to a pullrequest") { return .success(nil) }
            return .failure(LookUpFailure(reason: failure.message))
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let number = json["number"] as? Int, let state = json["state"] as? String, let url = json["url"] as? String
        else { return .failure(LookUpFailure(reason: "gh gave an answer Nirux couldn't read")) }
        return .success(LookedUp(number: number, state: GitHub.PullRequestState(state), url: url))
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

    /// How much of a held message a row's tooltip and list_tasks quote.
    static let quotedLength = 200
    /// How much of it a notice quotes: the Lead may want to send it again.
    static let noticeQuoteLength = 1_000

    /// How often GitHub is asked again while reads keep saying the same
    /// (no pull request, say, where it has one under another branch name),
    /// and a merged message that couldn't go is tried again.
    static let lookUpInterval: TimeInterval = 600
    /// Look-ups GitHub may leave unanswered, once the task is gone, before
    /// the wait gives up.
    static let maxUnansweredLookUps = 6
    /// How long a merged message that can't go is tried, as a tell waits
    /// for a free prompt.
    static let deliveryLifetime = MissionEventCLI.instructionLifetime
}
