import Foundation

/// GitHub's vocabulary as gh hands it over, read one way by every feature
/// that touches GitHub: the Board, the merge queue, CI triage, the
/// sidebar's pull request and the column headers.
enum GitHub {
    /// The server Nirux talks to. A call that names a repository names the
    /// host too (`--repo`, `--hostname`): a terminal's `GH_HOST` would
    /// otherwise send `owner/name` to another one.
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
    }

    /// Check run conclusions that make a check red, any case. NEUTRAL and
    /// SKIPPED are neither green nor red: CodeQL adds a NEUTRAL check to
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

    /// "nightly" for `nightly.yml`.
    static func workflowLabel(_ workflow: String) -> String {
        (workflow as NSString).deletingPathExtension
    }

    /// A start time as gh gives it; nil for none, or for gh's zero time
    /// ("0001-01-01…"), which a run not started yet carries.
    static func startTime(_ value: String?) -> String? {
        guard let value, !value.isEmpty, !value.hasPrefix("0001-") else { return nil }
        return value
    }

    /// The value at `path` in gh's JSON output.
    static func dig(_ json: Any?, _ path: String...) -> Any? {
        path.reduce(json) { value, key in (value as? [String: Any])?[key] }
    }
}
