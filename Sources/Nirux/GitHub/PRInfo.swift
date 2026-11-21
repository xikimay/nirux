import Foundation

/// A workspace branch's pull request as `PRDetect` reads it.
struct PRInfo: Hashable, Sendable {
    let number: Int
    let state: GitHub.PullRequestState
    let isDraft: Bool
    let ciStatus: String?
    /// The latest run of each check (docs/design/ci-failure-actions.md).
    let checks: [GitHub.Check]
    let reviewDecision: String?
    let mergeable: String?
    let url: String
    let additions: Int?
    let deletions: Int?
    let changedFiles: Int?
    /// Lowercased.
    var headRefOid: String?
    var baseRefName: String?
    /// GitHub merges it once its checks pass.
    var autoMerges = false
    var createdAt: String?

    var failedCheckUrl: String? {
        checks.lazy.filter { $0.result == .failure }.compactMap(\.url).first
    }
}
