import Foundation

/// The two actions on a workspace pull request whose CI turned red
/// (docs/ci-failure-actions.md). Both work on GitHub Actions runs only,
/// parsed out of the red checks' URLs: what GitHub returns is never typed
/// into an agent or passed to `gh` as is.
enum CIFailure {
    struct Run: Equatable {
        /// `host/owner/name`, as `gh --repo` takes it.
        let repository: String
        let id: Int
    }

    /// `https://<host>/<owner>/<name>/actions/runs/<id>[/job/<job>]`.
    static func run(checkURL: String) -> Run? {
        guard let components = URLComponents(string: checkURL), components.scheme == "https",
              let host = components.host?.lowercased(), host.allSatisfy(isHostCharacter)
        else { return nil }
        let path = components.path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().map(String.init)
        guard path.count >= 5, path[2] == "actions", path[3] == "runs",
              [path[0], path[1]].allSatisfy({ !$0.isEmpty && $0.allSatisfy(isNameCharacter) }),
              path[4].allSatisfy({ $0.isASCII && $0.isNumber }), let id = Int(path[4])
        else { return nil }
        return Run(repository: "\(host)/\(path[0])/\(path[1])", id: id)
    }

    /// The Actions runs of `redChecks`, each once, in order.
    static func runs(_ redChecks: [PRInfo.RedCheck]) -> [Run] {
        var runs: [Run] = []
        for run in redChecks.compactMap({ $0.url.flatMap(run(checkURL:)) }) where !runs.contains(run) {
            runs.append(run)
        }
        return runs
    }

    static func whyFailedPrompt(pullRequest: Int, runs: [Run]) -> String {
        let commands = runs.map { "`gh run view \($0.id) --repo \($0.repository) --log-failed`" }
        return "CI failed on PR #\(pullRequest). Run \(commands.joined(separator: " and ")), then tell me why it failed."
    }

    /// The merge queue's own rerun (docs/project-board.md, section 3.2).
    static func rerunArguments(_ run: Run) -> [String] {
        ["run", "rerun", "\(run.id)", "--repo", run.repository, "--failed"]
    }

    private static func isHostCharacter(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber || character == "." || character == "-")
    }

    private static func isNameCharacter(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber || "._-".contains(character))
    }
}
