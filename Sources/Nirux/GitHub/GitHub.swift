import Foundation

/// GitHub's vocabulary as gh hands it over, read one way by every feature
/// that touches GitHub: the Board, the merge queue, CI triage, the
/// sidebar's pull request and the column headers.
enum GitHub {
    /// The host of the repositories board.json and the merge queue name.
    /// PRFeedback and CIFailure take the host from the pull request's own
    /// address instead.
    static let host = "github.com"

    /// Whether `host` is github.com, its SSH endpoint included.
    static func isGitHubHost(_ host: String) -> Bool {
        GitHubRepository.normalizedHost(host) == Self.host
    }

    /// A pull request's state, whatever case gh spells it in.
    enum PullRequestState: String, Equatable, Hashable, Sendable {
        case open = "OPEN"
        case closed = "CLOSED"
        case merged = "MERGED"

        init?(_ value: String?) {
            guard let value, let state = Self(rawValue: value.uppercased()) else { return nil }
            self = state
        }

        /// "open", "closed", "merged".
        var word: String { rawValue.lowercased() }
    }

    /// Check run conclusions that make a check red, any case: a CI triage
    /// job's too, as a job and its check must agree on what is red. NEUTRAL
    /// and SKIPPED are neither green nor red: CodeQL adds a NEUTRAL check to
    /// every pull request.
    static func isRedCheck(_ conclusion: String?) -> Bool {
        ["FAILURE", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE", "STALE"]
            .contains(conclusion?.uppercased() ?? "")
    }

    /// Whether a finished workflow run failed: a cancelled, skipped or
    /// neutral one didn't.
    static func isFailedRun(_ conclusion: String?) -> Bool {
        ["FAILURE", "TIMED_OUT", "STARTUP_FAILURE", "ACTION_REQUIRED"].contains(conclusion?.uppercased() ?? "")
    }

    static func isSucceededRun(_ conclusion: String?) -> Bool {
        conclusion?.uppercased() == "SUCCESS"
    }

    /// "nightly" for `nightly.yml`; "post-merge workflow" when none is set.
    static func workflowLabel(_ workflow: String?) -> String {
        workflow.map { ($0 as NSString).deletingPathExtension } ?? "post-merge workflow"
    }

    /// A start time as gh gives it; nil for none, or for gh's zero time
    /// ("0001-01-01…"), which a run not started yet carries.
    static func startTime(_ value: String?) -> String? {
        guard let value, !value.isEmpty, !value.hasPrefix("0001-") else { return nil }
        return value
    }

    static func dig(_ json: Any?, _ path: String...) -> Any? {
        path.reduce(json) { value, key in (value as? [String: Any])?[key] }
    }

    /// A full commit SHA, lowercased; nil for anything else.
    static func objectID(_ value: Any?) -> String? {
        guard let value = value as? String, [40, 64].contains(value.count), value.allSatisfy(\.isHexDigit) else { return nil }
        return value.lowercased()
    }
}
