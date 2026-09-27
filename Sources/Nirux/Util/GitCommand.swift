import Foundation

/// Git queries for the editor (file tree changes, diff originals). They go
/// through `BoundedProcess`, which reads stdout while git runs: reading
/// only after `waitUntilExit()` wedges git, and the waiting thread, as soon
/// as the output outgrows the 64 KiB pipe buffer (`git show` of a large
/// file, `git status` of a big change set).
enum GitCommand {
    /// A last resort for a wedged git, not an expected outcome: generous so
    /// a cold `git status` in a large repository still completes.
    static let defaultTimeout: TimeInterval = 60

    /// Standard output of a git that exits 0, decoded as UTF-8 (empty if it
    /// is not UTF-8). Nil when git fails, cannot start or outlives
    /// `timeout`. Standard error is discarded. Runs without optional locks,
    /// so `git status` neither rewrites the index nor, killed at the
    /// timeout, leaves an `index.lock` behind.
    static func output(
        _ arguments: [String],
        cwd: String,
        gitPath: String = "/usr/bin/git",
        timeout: TimeInterval = defaultTimeout
    ) -> String? {
        guard let result = BoundedProcess.run(
            executableURL: URL(fileURLWithPath: gitPath),
            arguments: arguments,
            currentDirectoryURL: URL(fileURLWithPath: cwd),
            environment: GitDetect.readOnlyEnvironment,
            timeout: timeout
        ) else {
            NSLog("[GitCommand] git %@ did not start or finish in %@", arguments.first ?? "", cwd)
            return nil
        }
        guard result.terminationStatus == 0 else { return nil }
        return String(data: result.standardOutput, encoding: .utf8) ?? ""
    }

    /// The merge-base of HEAD with its upstream, else with the first
    /// default branch that exists: the base "branch" diffs compare against.
    static func branchBaseRef(cwd: String, gitPath: String = "/usr/bin/git") -> String? {
        for candidate in ["@{upstream}", "origin/main", "origin/master", "main", "master"] {
            guard let output = output(["merge-base", "HEAD", candidate], cwd: cwd, gitPath: gitPath)
            else { continue }
            let sha = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !sha.isEmpty { return sha }
        }
        return nil
    }
}
